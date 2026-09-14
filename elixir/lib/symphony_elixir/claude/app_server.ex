defmodule SymphonyElixir.Claude.AppServer do
  @moduledoc """
  Client for driving the Claude Code CLI in non-interactive (`-p`) mode.

  Unlike the Codex app-server (one long-lived JSON-RPC process per session, with
  Elixir answering tool calls inline), the Claude CLI is spawned fresh per turn
  and talks to tracker tools over its own MCP stdio connection to
  `SymphonyElixir.MCP.ToolBridge` (see `symphony mcp-tool-bridge`). Elixir only
  observes the turn's `--output-format stream-json` events for logging and
  dashboard reporting; it never proxies tool calls itself.

  Continuity across continuation turns is done with `--resume <session_id>`,
  where `session_id` comes from the previous turn's `result` event. That id is
  held in a small `Agent` (see `state` in `session/0`) since each `run_turn/4`
  call spawns and tears down its own OS process.

  Only local execution is supported today: the MCP tool bridge would need to
  run on the worker host for `worker_host` sessions, which is not wired up, so
  `start_session/2` rejects that combination explicitly rather than silently
  failing to reach tracker tools.

  Note on secrets: unlike Codex, the Claude CLI's own process env is left
  intact (not stripped) so that tracker credentials configured as `$ENV_VAR`
  references in `WORKFLOW.md` can flow down to the MCP tool bridge process it
  spawns as its own child. This is a deliberate, documented difference from the
  Codex backend's tool-secret isolation.
  """

  @behaviour SymphonyElixir.AgentBackend

  require Logger
  alias SymphonyElixir.{Codex.DynamicTool, Config, PathSafety, Workflow}

  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          workspace: Path.t(),
          dynamic_tool_binding: map(),
          mcp_config_path: Path.t(),
          state: pid()
        }

  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, opts \\ []) do
    case Keyword.get(opts, :worker_host) do
      nil -> start_local_session(workspace)
      worker_host -> {:error, {:unsupported_remote_claude_backend, worker_host}}
    end
  end

  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{workspace: workspace, mcp_config_path: mcp_config_path, state: state},
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    settings = Config.settings!().claude
    session_id = Agent.get(state, & &1.session_id)

    case start_port(workspace, settings, mcp_config_path, prompt, session_id) do
      {:ok, port} ->
        metadata = port_metadata(port)
        Logger.info("Claude turn started for #{issue_context(issue)} workspace=#{workspace}")

        case await_turn_completion(port, on_message, metadata, settings.turn_timeout_ms) do
          {:ok, %{session_id: new_session_id} = result} ->
            Agent.update(state, &Map.put(&1, :session_id, new_session_id))
            Logger.info("Claude turn completed for #{issue_context(issue)} session_id=#{inspect(new_session_id)}")
            {:ok, result}

          {:error, reason} = error ->
            Logger.warning("Claude turn ended with error for #{issue_context(issue)}: #{inspect(reason)}")
            emit_message(on_message, :turn_ended_with_error, %{reason: reason}, metadata)
            error
        end

      {:error, reason} ->
        Logger.error("Claude turn failed to start for #{issue_context(issue)}: #{inspect(reason)}")
        emit_message(on_message, :startup_failed, %{reason: reason}, %{})
        {:error, reason}
    end
  end

  @spec stop_session(session()) :: :ok
  def stop_session(%{mcp_config_path: mcp_config_path, state: state}) do
    if Process.alive?(state), do: Agent.stop(state)
    _ = File.rm(mcp_config_path)
    :ok
  end

  defp start_local_session(workspace) do
    dynamic_tool_binding = DynamicTool.bind()

    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, mcp_config_path} <- write_mcp_config(expanded_workspace),
         {:ok, state} <- Agent.start_link(fn -> %{session_id: nil} end) do
      {:ok,
       %{
         workspace: expanded_workspace,
         dynamic_tool_binding: dynamic_tool_binding,
         mcp_config_path: mcp_config_path,
         state: state
       }}
    end
  end

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Config.local_workspace_root()
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  defp write_mcp_config(workspace) do
    settings = Config.settings!().claude
    [command | base_args] = settings.mcp_bridge_command |> String.trim() |> String.split()

    config = %{
      "mcpServers" => %{
        "symphony-tracker" => %{
          "command" => command,
          "args" => base_args ++ ["--workflow", Workflow.workflow_file_path()]
        }
      }
    }

    dir = Path.join(workspace, ".symphony")
    path = Path.join(dir, "mcp-config.json")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, Jason.encode!(config)),
         :ok <- File.chmod(path, 0o600) do
      {:ok, path}
    end
  end

  defp start_port(workspace, settings, mcp_config_path, prompt, session_id) do
    [claude_exe | base_args] = settings.command |> String.trim() |> String.split()

    case System.find_executable(claude_exe) do
      nil ->
        {:error, {:claude_executable_not_found, claude_exe}}

      executable ->
        args = base_args ++ turn_args(settings, mcp_config_path, prompt, session_id)

        port =
          Port.open(
            {:spawn_executable, String.to_charlist(executable)},
            [
              :binary,
              :exit_status,
              :stderr_to_stdout,
              args: Enum.map(args, &String.to_charlist/1),
              cd: String.to_charlist(workspace),
              line: @port_line_bytes
            ]
          )

        {:ok, port}
    end
  end

  defp turn_args(settings, mcp_config_path, prompt, session_id) do
    [
      "-p",
      prompt,
      "--output-format",
      "stream-json",
      "--verbose",
      "--permission-mode",
      settings.permission_mode,
      "--mcp-config",
      mcp_config_path
    ]
    |> maybe_append_model(settings.model)
    |> maybe_append_resume(session_id)
  end

  defp maybe_append_model(args, model) when is_binary(model) and model != "", do: args ++ ["--model", model]
  defp maybe_append_model(args, _model), do: args

  defp maybe_append_resume(args, session_id) when is_binary(session_id), do: args ++ ["--resume", session_id]
  defp maybe_append_resume(args, _session_id), do: args

  defp await_turn_completion(port, on_message, metadata, timeout_ms) do
    receive_loop(port, on_message, metadata, timeout_ms, "")
  end

  defp receive_loop(port, on_message, metadata, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        handle_incoming(port, on_message, metadata, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, on_message, metadata, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, on_message, metadata, timeout_ms, line) do
    case Jason.decode(line) do
      {:ok, %{"type" => "system"} = payload} ->
        emit_message(
          on_message,
          :session_started,
          %{payload: payload, raw: line, session_id: message_session_id(payload)},
          metadata
        )

        receive_loop(port, on_message, metadata, timeout_ms, "")

      {:ok, %{"type" => "result"} = payload} ->
        handle_result(payload, line, on_message, metadata)

      {:ok, %{"type" => "error"} = payload} ->
        emit_message(on_message, :turn_failed, %{payload: payload, raw: line}, metadata)
        {:error, {:turn_failed, payload}}

      {:ok, payload} ->
        emit_message(on_message, :notification, %{payload: payload, raw: line}, metadata)
        receive_loop(port, on_message, metadata, timeout_ms, "")

      {:error, _reason} ->
        log_non_json_stream_line(line)
        receive_loop(port, on_message, metadata, timeout_ms, "")
    end
  end

  defp handle_result(payload, line, on_message, metadata) do
    session_id = message_session_id(payload)
    usage = Map.get(payload, "usage")

    if result_success?(payload) do
      emit_message(
        on_message,
        :turn_completed,
        %{
          payload: %{"method" => "turn/completed", "usage" => usage},
          raw: line,
          session_id: session_id,
          usage: usage
        },
        metadata
      )

      {:ok, %{session_id: session_id, result: Map.get(payload, "result")}}
    else
      emit_message(on_message, :turn_failed, %{payload: payload, raw: line, session_id: session_id}, metadata)
      {:error, {:turn_failed, payload}}
    end
  end

  defp result_success?(%{"is_error" => true}), do: false
  defp result_success?(%{"subtype" => subtype}) when is_binary(subtype), do: String.starts_with?(subtype, "success")
  defp result_success?(_payload), do: true

  defp message_session_id(%{"session_id" => session_id}) when is_binary(session_id), do: session_id
  defp message_session_id(_payload), do: nil

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} -> %{codex_app_server_pid: to_string(os_pid)}
      _ -> %{}
    end
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message = metadata |> Map.merge(details) |> Map.put(:event, event) |> Map.put(:timestamp, DateTime.utc_now())
    on_message.(message)
  end

  defp log_non_json_stream_line(data) do
    text = data |> to_string() |> String.trim() |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("Claude turn stream output: #{text}")
      else
        Logger.debug("Claude turn stream output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  defp default_on_message(_message), do: :ok
end
