defmodule SymphonyElixir.AgentBackendTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.AgentBackend

  defp issue(labels) do
    %Issue{id: "issue-1", identifier: "SYM-1", labels: labels, dispatchable: true}
  end

  test "an agent: label picks the Claude backend regardless of casing or spacing" do
    assert AgentBackend.resolve(issue(["bug", " Agent:Claude "])) == SymphonyElixir.Claude.AppServer
  end

  test "a backend: label picks the Codex backend even when the default is Claude" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude")

    assert AgentBackend.resolve(issue(["backend:codex"])) == SymphonyElixir.Codex.AppServer
  end

  test "falls back to the configured default backend when no routing label is present" do
    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "claude")
    assert AgentBackend.resolve(issue(["bug"])) == SymphonyElixir.Claude.AppServer

    write_workflow_file!(Workflow.workflow_file_path(), agent_backend: "codex")
    assert AgentBackend.resolve(issue([])) == SymphonyElixir.Codex.AppServer
  end

  test "an unrecognized backend label falls back to Codex instead of crashing dispatch" do
    assert AgentBackend.resolve(issue(["agent:gpt5"])) == SymphonyElixir.Codex.AppServer
  end
end
