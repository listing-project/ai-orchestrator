defmodule SymphonyElixir.RoleRouterTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.RoleRouter

  defp issue(state) do
    %Issue{id: "issue-1", identifier: "SYM-1", state: state, labels: [], dispatchable: true}
  end

  defp configure_roles! do
    write_workflow_file!(Workflow.workflow_file_path(),
      roles: [
        %{
          name: "planner",
          states: ["Plan Todo", "Planning"],
          entry_states: ["Plan Todo"],
          active_state: "Planning",
          success_state: "Plan Review",
          command: "/planner"
        },
        %{
          name: "developer",
          states: ["Todo", "In Progress", "Rework"],
          entry_states: ["Todo", "Rework"],
          active_state: "In Progress",
          success_state: "Review",
          command: "/developer"
        }
      ]
    )
  end

  test "returns nil when no roles are configured" do
    assert RoleRouter.resolve(issue("Todo")) == nil
  end

  test "routes an entry state to its role with needs_entry_transition true" do
    configure_roles!()

    assert RoleRouter.resolve(issue("Plan Todo")) == %{
             name: "planner",
             command: "/planner",
             active_state: "Planning",
             success_state: "Plan Review",
             needs_entry_transition: true
           }
  end

  test "routes an active (resume) state to its role with needs_entry_transition false" do
    configure_roles!()

    assert RoleRouter.resolve(issue("Planning")) == %{
             name: "planner",
             command: "/planner",
             active_state: "Planning",
             success_state: "Plan Review",
             needs_entry_transition: false
           }
  end

  test "routes every developer entry state to the developer role" do
    configure_roles!()

    for state <- ["Todo", "Rework"] do
      assert %{name: "developer", needs_entry_transition: true} = RoleRouter.resolve(issue(state))
    end

    assert %{name: "developer", needs_entry_transition: false} = RoleRouter.resolve(issue("In Progress"))
  end

  test "state matching ignores case and surrounding whitespace" do
    configure_roles!()

    assert %{name: "planner"} = RoleRouter.resolve(issue(" plan todo "))
  end

  test "returns nil for a state with no matching role" do
    configure_roles!()

    assert RoleRouter.resolve(issue("Backlog")) == nil
  end

  test "returns nil for an issue with a nil state" do
    configure_roles!()

    assert RoleRouter.resolve(issue(nil)) == nil
  end
end
