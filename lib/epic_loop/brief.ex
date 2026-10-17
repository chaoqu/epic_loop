defmodule EpicLoop.Brief do
  @moduledoc "The worker brief: self-contained, written to .agent_artifact/epic-loop/brief.md in the worktree."

  @prompt_text "Read ./.agent_artifact/epic-loop/brief.md in this directory and carry out the ticket exactly as it says. When you finish, write ./.agent_artifact/epic-loop/report.json as the brief specifies, then stop."
  def prompt_text, do: @prompt_text

  def build(%{ticket: t, epic: epic, cfg: cfg, branch: branch, attempt: attempt, extra: extra}) do
    rules = case get_in(cfg, ["worker", "rulesFile"]), do: (nil -> ""; f -> File.read!(f))
    checks = t.checks |> Enum.map(&"- `#{&1}`") |> Enum.join("\n")
    repo_checks = case get_in(cfg, ["verify", "repoChecks"]) || [] do
      [] -> ""
      list -> "\n\nRepository-wide checks, run for every ticket in this repository:\n" <> Enum.map_join(list, "\n", &"- `#{&1}`")
    end
    owned = t.owned |> Enum.map(&"- #{&1}") |> Enum.join("\n")
    notes = if t.notes != "", do: "\n## Notes from earlier attempts\n#{String.trim(t.notes)}\n", else: ""
    extra = if extra, do: "\n## This attempt\n#{String.trim(extra)}\n", else: ""
    prefix = case cfg["commitPrefix"], do: (p when p in [nil, ""] -> ""; p -> " with a message starting `#{p}`")

    """
    # Ticket #{t.id}: #{t.title}

    You are a worker in an automated loop. This file is your whole brief; do not look for the epic, other tickets, or other workers.
    You are in a dedicated git worktree on branch `#{branch}`. Commit here. Do not create branches, do not push, do not open pull requests, do not touch git config.

    ## Epic
    #{epic["title"]}
    #{String.trim(epic["description"] || "")}

    ## Task
    #{String.trim(t.description)}
    #{notes}#{extra}
    ## Owned paths (hard boundary)
    Only files under these paths may be created, changed or deleted. A diff outside them fails verification.
    #{owned}

    ## Acceptance checks
    The orchestrator runs each of these from the worktree root after you stop. Every one must exit 0. Run them yourself before you finish.
    #{checks}#{repo_checks}

    ## Rules
    #{String.trim(rules)}

    ## When you finish
    1. Run the acceptance checks and make sure they pass.
    2. Commit all work#{prefix}. Leave nothing uncommitted. The loop merges commits only, so a ticket that changes no tracked file (a manual step, or owned paths the repository ignores) still ends with one commit: make it with `git commit --allow-empty`, its message saying what was done.
    3. Write `.agent_artifact/epic-loop/report.json` in the worktree (the folder is ignored by the repository; never commit it) with exactly this shape, then stop and do not start anything else:
    ```json
    {
      "status": "done | failed | needs-human",
      "ticket": "#{t.id}",
      "commits": ["<sha>"],
      "checks": [{ "cmd": "<command>", "result": "pass | fail" }],
      "changed_paths": ["<path>"],
      "question": "only with needs-human: one question a yes/no or a choice can settle",
      "options": ["A", "B"],
      "unblock": "what the answer decides",
      "notes": "what the next worker in this worktree must know"
    }
    ```
    Use `needs-human` only when the brief truly does not settle something; asking in prose does nothing, only the file is read.
    Attempt #{attempt}.
    """
  end
end
