defmodule SymphonyElixir.AgentBackend do
  @moduledoc """
  Shared contract implemented by every coding-agent backend (Codex, Claude) and
  the resolver that picks which backend drives a given issue.

  Resolution order: an `agent:<backend>` or `backend:<backend>` label on the
  issue wins; otherwise the workflow-wide `agent.backend` setting applies. This
  lets a team default to one backend while routing individual tickets to the
  other by label, without restarting Symphony.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @backend_label_prefixes ["agent:", "backend:"]

  @type session :: term()

  @callback start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  @callback run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop_session(session()) :: :ok

  @doc """
  Picks the backend module (`SymphonyElixir.Codex.AppServer` or
  `SymphonyElixir.Claude.AppServer`) that should run the given issue.
  """
  @spec resolve(Issue.t()) :: module()
  def resolve(%Issue{} = issue) do
    issue
    |> Issue.label_names()
    |> backend_name_from_labels()
    |> case do
      nil -> Config.settings!().agent.backend
      name -> name
    end
    |> backend_module()
  end

  defp backend_name_from_labels(labels) when is_list(labels) do
    Enum.find_value(labels, &label_backend_name/1)
  end

  defp label_backend_name(label) when is_binary(label) do
    normalized = label |> String.trim() |> String.downcase()

    Enum.find_value(@backend_label_prefixes, fn prefix ->
      if String.starts_with?(normalized, prefix) do
        String.trim_leading(normalized, prefix)
      end
    end)
  end

  defp backend_module("claude"), do: SymphonyElixir.Claude.AppServer
  defp backend_module(_name), do: SymphonyElixir.Codex.AppServer
end
