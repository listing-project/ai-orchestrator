defmodule SymphonyElixir.MCP.ToolBridge do
  @moduledoc """
  Minimal MCP (Model Context Protocol) server over stdio.

  Exposes Symphony's tracker-native agent tools (Linear/Jira/GitHub/Asana/
  GitLab) to the Claude Code CLI, which spawns this as its own MCP child
  process per `--mcp-config` (see `SymphonyElixir.Claude.AppServer`) and is
  invoked as `symphony mcp-tool-bridge --workflow <path-to-WORKFLOW.md>`.

  Reuses the same tool binding/execution the Codex backend calls in-process
  (`SymphonyElixir.Codex.DynamicTool`, itself a thin wrapper over
  `SymphonyElixir.Tracker`) so tool behavior never drifts between backends.
  """

  require Logger
  alias SymphonyElixir.Codex.DynamicTool

  @protocol_version "2024-11-05"

  @doc """
  Blocks, serving JSON-RPC 2.0 requests read line-by-line from stdin until the
  client closes the pipe (Claude Code exiting the turn tears this process
  down along with it).
  """
  @spec serve() :: :ok
  def serve do
    loop(DynamicTool.bind())
  end

  defp loop(binding) do
    case IO.gets(:stdio, "") do
      :eof -> :ok
      {:error, _reason} -> :ok
      data -> data |> String.trim() |> handle_line(binding)
    end
  end

  defp handle_line("", binding), do: loop(binding)

  defp handle_line(line, binding) do
    case Jason.decode(line) do
      {:ok, request} ->
        request |> handle_request(binding) |> write_response()
        loop(binding)

      {:error, reason} ->
        Logger.warning("Ignoring non-JSON MCP tool bridge input: #{inspect(reason)}")
        loop(binding)
    end
  end

  defp write_response(nil), do: :ok
  defp write_response(response), do: IO.write(:stdio, Jason.encode!(response) <> "\n")

  defp handle_request(%{"id" => id, "method" => "initialize"}, _binding) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "result" => %{
        "protocolVersion" => @protocol_version,
        "capabilities" => %{"tools" => %{}},
        "serverInfo" => %{"name" => "symphony-tracker", "version" => "0.1.0"}
      }
    }
  end

  defp handle_request(%{"id" => id, "method" => "tools/list"}, binding) do
    %{"jsonrpc" => "2.0", "id" => id, "result" => %{"tools" => binding.tool_specs}}
  end

  defp handle_request(%{"id" => id, "method" => "tools/call", "params" => params}, binding) do
    name = Map.get(params, "name")
    arguments = Map.get(params, "arguments") || %{}
    result = DynamicTool.execute(name, arguments, binding)

    %{"jsonrpc" => "2.0", "id" => id, "result" => tool_call_result(result)}
  end

  defp handle_request(%{"id" => id}, _binding) do
    %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => -32601, "message" => "Method not found"}}
  end

  defp handle_request(_notification, _binding), do: nil

  defp tool_call_result(%{"success" => success, "output" => output}) when is_boolean(success) and is_binary(output) do
    %{"content" => [%{"type" => "text", "text" => output}], "isError" => !success}
  end

  defp tool_call_result(result) do
    %{"content" => [%{"type" => "text", "text" => inspect(result)}], "isError" => true}
  end
end
