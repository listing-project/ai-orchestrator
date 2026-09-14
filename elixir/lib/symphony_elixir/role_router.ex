defmodule SymphonyElixir.RoleRouter do
  @moduledoc """
  Resolves which configured role, if any, applies to an issue's current
  tracker state.

  A role maps one or more tracker states to a project-defined agent command
  (typically a `.claude/commands/<name>.md` or `.claude/agents/<name>.md` in
  the target repository) plus the state transitions around it. Symphony never
  inspects or duplicates what that command actually does; the prompt template
  only tells the agent which command to invoke and which Linear states to
  move through, exactly like it already does for `attempt`.

  This makes multi-stage workflows (e.g. a planning stage followed by an
  implementation stage) entirely project-configured: a different repository
  can define its own roles in its own `WORKFLOW.md` without any change to
  Symphony itself. When `roles` is left empty, `resolve/1` always returns
  `nil` and prompts fall back to the single generic template, unchanged from
  before this feature existed.
  """

  alias SymphonyElixir.Config
  alias SymphonyElixir.Tracker.Issue

  @type resolved :: %{
          name: String.t(),
          command: String.t(),
          active_state: String.t(),
          success_state: String.t(),
          needs_entry_transition: boolean()
        }

  @doc """
  Finds the configured role whose `states` list contains the issue's current
  state (case- and whitespace-insensitive, same normalization as
  `tracker.required_labels`), and reports whether that state is one of the
  role's `entry_states` — i.e. whether the agent still needs to move the
  issue to `active_state` before starting, versus resuming work already in
  `active_state`.

  Returns `nil` when no roles are configured, or none match the issue's
  state.
  """
  @spec resolve(Issue.t()) :: resolved() | nil
  def resolve(%Issue{state: state}) do
    Config.settings!().roles
    |> Enum.find(&role_matches_state?(&1, state))
    |> to_resolved(state)
  end

  defp role_matches_state?(%{states: states}, state) do
    state_in?(states, state)
  end

  defp to_resolved(nil, _state), do: nil

  defp to_resolved(role, state) do
    %{
      name: role.name,
      command: role.command,
      active_state: role.active_state,
      success_state: role.success_state,
      needs_entry_transition: state_in?(role.entry_states, state)
    }
  end

  defp state_in?(states, state) when is_list(states) and is_binary(state) do
    normalized = normalize(state)
    Enum.any?(states, &(normalize(&1) == normalized))
  end

  defp state_in?(_states, _state), do: false

  defp normalize(value) when is_binary(value) do
    value |> String.trim() |> String.downcase()
  end
end
