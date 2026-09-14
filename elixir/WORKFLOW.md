---
tracker:
  kind: linear
  provider:
    project_slug: ai-development-8144e9dd30ed
  required_labels: []
  active_states:
    - Planning
    - Todo
    - In Progress
    - Rework
  terminal_states:
    - Canceled
    - Duplicate
    - Done

polling:
  interval_ms: 5000

workspace:
  root: ~/code/symphony-workspaces

hooks:
  after_create: |
    git clone --depth 1 git@github.com:listing-project/difmark.git .
  before_remove: |
    true

agent:
  max_concurrent_agents: 10
  max_turns: 20

codex:
  command: codex --config shell_environment_policy.inherit=all --config 'model="gpt-5.5"' --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true

claude:
  mcp_bridge_command: /var/www/ai-orchestrator/elixir/bin/symphony mcp-tool-bridge
---

You are working on Linear ticket `{{ issue.identifier }}`.

{% if attempt %}
Follow-up context:

- This is follow-up attempt #{{ attempt }}.
- Resume from the existing workspace state when appropriate.
- Do not repeat completed investigation or validation unless the new work requires it.
  {% endif %}

## Issue

Identifier: {{ issue.identifier }}
Title: {{ issue.title }}
Current status: {{ issue.state }}
Labels: {{ issue.labels }}
URL: {{ issue.url }}

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description provided.
{% endif %}

## Goal

Implement the Linear ticket completely and prepare the result for human review.

You may:
- inspect and modify code in the provided workspace;
- run relevant static checks and tests that are available in the workspace;
- create commits;
- push the working branch;
- create or update a pull request;
- update the Linear ticket and its workpad comment.

You must NOT:
- merge a pull request;
- move an issue from `Review` to `Done`;
- modify code outside the provided workspace;
- deploy changes to production;
- perform destructive operations against shared environments;
- expand the ticket scope with unrelated improvements.

Human approval is required after implementation.

## Workflow

The workflow is:

`Backlog -> Todo -> In Progress -> Review`

If human review fails:

`Review -> Rework -> In Progress -> Review`

If human review succeeds, the human merges the pull request and moves the ticket to `Done`.

`Canceled`, `Duplicate`, and `Done` are terminal states.

### Backlog

`Backlog` means the issue has not been approved for agent execution.

Do not modify or execute Backlog issues.

A human starts work by moving an issue from `Backlog` to `Todo`.

### Todo

`Todo` means the issue is ready for autonomous execution.

When starting a Todo issue:

1. Move it immediately to `In Progress`.
2. Find or create the single `## Agent Workpad` comment.
3. Inspect the repository and understand the task.
4. Build a concrete implementation and validation plan.
5. Execute the task.
6. Validate the result.
7. Commit and push the changes.
8. Create or update the pull request.
9. Update the workpad with the final result.
10. Move the issue to `Review`.

### In Progress

`In Progress` means implementation is actively being performed.

Continue from the current workspace and workpad.

Do not restart completed work unnecessarily.

When implementation and validation are complete:

1. ensure all intended changes are committed;
2. push the branch;
3. create or update the pull request;
4. record validation results in the workpad;
5. move the issue to `Review`.

### Review

`Review` is a HUMAN-ONLY state.

When an issue reaches Review:

- stop implementation;
- do not modify code;
- do not merge the pull request;
- do not move the issue to Done;
- wait for a human decision.

The human will either:

- merge the pull request and move the issue to `Done`; or
- request changes and move the issue to `Rework`.

### Rework

`Rework` means human review found problems that must be corrected.

When starting Rework:

1. Read the complete Linear issue.
2. Read the existing `## Agent Workpad`.
3. Read all new human comments and review feedback.
4. Inspect the existing pull request and its review comments.
5. Determine exactly what failed review.
6. Move the issue to `In Progress`.
7. Update the existing workpad with the required corrections.
8. Modify the existing implementation.
9. Run the required validation again.
10. Commit and push the corrections to the existing branch/PR when possible.
11. Update the workpad.
12. Move the issue back to `Review`.

Do NOT automatically throw away the existing implementation, close the PR, or create a new branch merely because the issue entered Rework.

Only restart from a clean branch when the existing approach is fundamentally unusable.

### Done

Done is terminal.

Do nothing.

### Canceled

Canceled is terminal.

Do nothing.

### Duplicate

Duplicate is terminal.

Do nothing.

## Linear interaction

Use the available Linear integration (`linear_graphql` or equivalent) to keep the ticket synchronized with actual work.

Maintain exactly one persistent comment with this marker:

`## Agent Workpad`

Reuse and update that comment instead of creating a new progress comment for every action.

Do not use the issue description as a scratchpad.

The workpad is the source of truth for:

- implementation plan;
- acceptance criteria;
- progress;
- validation;
- important technical decisions;
- blockers;
- review/rework notes.

## Starting work

Before modifying code:

1. Read the entire issue.
2. Read existing comments and review context.
3. Inspect the relevant code.
4. Check the current Git state.
5. Understand the existing behavior.
6. Determine the smallest correct scope for the ticket.
7. Create or update the workpad.

Do not begin implementation based only on the issue title.

When fixing a bug, reproduce or otherwise establish evidence of the current incorrect behavior whenever reasonably possible.

## Workpad format

Keep one persistent Linear comment in this form:

```md
## Agent Workpad

### Plan

- [ ] Task 1
- [ ] Task 2

### Acceptance Criteria

- [ ] Criterion 1
- [ ] Criterion 2

### Validation

- [ ] Check/test and result

### Notes

- Important discoveries, decisions and progress.

### Review / Rework

- Human review feedback and how it was addressed, when applicable.

### Blockers

- Only actual external blockers, when applicable.
```

Update checklist items as work progresses.

Do not leave completed work marked as incomplete.

## Implementation rules

Prefer the smallest change that correctly solves the ticket.

Follow the architecture, conventions and style of the existing repository.

Before introducing a new abstraction, verify that an appropriate abstraction does not already exist.

Do not perform unrelated refactoring.

Do not silently fix unrelated problems.

If you discover an unrelated issue, record it briefly in the workpad. Do not expand the current ticket scope unless it is necessary for correctness.

Read surrounding code before changing it.

Preserve backward compatibility unless the ticket explicitly requires otherwise.

## Validation

Validation must be proportional to the change.

Use the strongest validation available inside the provided environment, for example:

- existing automated tests;
- targeted tests;
- static analysis;
- linters;
- syntax checks;
- build commands;
- deterministic reproduction scripts.

If the ticket contains a `Validation`, `Testing`, `Test Plan`, or equivalent section, treat it as required acceptance criteria.

Never claim a test passed unless it was actually executed successfully.

If some validation cannot be executed because the isolated workspace does not contain the required runtime or infrastructure:

1. do not pretend it was executed;
2. record exactly what was and was not validated;
3. continue with all validation that is possible;
4. expose the missing runtime validation clearly in the workpad for human review.

A missing full application runtime is not automatically a reason to abandon implementation if the task can still be safely implemented and partially validated from the isolated workspace.

## Git

Before implementation, inspect:

- current branch;
- `git status`;
- current HEAD;
- relevant recent history when useful.

Keep commits focused on the ticket.

Do not include unrelated files.

Before pushing:

1. inspect the diff;
2. verify no secrets or temporary debugging changes were added;
3. run the appropriate available validation.

Create or update a pull request for completed implementation.

Never merge the pull request.

## Pull request

The PR should make human review easy.

Its description should contain:

- what problem was solved;
- what changed;
- how it was validated;
- anything that could not be validated;
- important risks or assumptions.

Before moving the ticket to Review:

1. verify the final diff;
2. verify the branch is pushed;
3. verify a PR exists;
4. inspect existing PR review comments;
5. address actionable feedback that is already present;
6. ensure validation results are recorded;
7. ensure the Linear workpad accurately represents the final state.

Then move the ticket to `Review`.

## Human review boundary

Human review is a hard boundary.

The agent must never interpret successful tests, an approved automated review, or its own confidence as permission to merge.

Only a human may decide that the work is accepted.

Therefore:

- agent creates code;
- agent validates code;
- agent creates PR;
- agent moves issue to Review;
- human reviews;
- human either requests Rework or merges;
- human moves successfully merged issue to Done.

## Blockers

Only treat something as blocked when an external dependency genuinely prevents useful progress, such as:

- missing required credentials;
- missing repository access;
- missing required external service access;
- permissions that cannot be worked around safely.

Before declaring a blocker, complete all useful work that does not depend on the blocker.

Record blockers in the workpad with:

- what is missing;
- what work was completed;
- what could not be completed;
- what human action is required.

Do not invent successful completion when blocked.

## Final behavior

Do not stop while an issue remains `Todo`, `In Progress`, or `Rework` unless there is a genuine external blocker.

A successful implementation session should normally finish with the issue in:

`Review`

At that point stop and wait for human action.