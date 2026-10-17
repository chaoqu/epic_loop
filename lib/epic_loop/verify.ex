defmodule EpicLoop.Verify do
  @moduledoc "Verification the worker cannot argue with: rerun the checks, bound the diff, protect tests."
  alias EpicLoop.{Git, Sh, Tickets}

  def run(wt, ticket, base, cfg) do
    files = Git.changed_files(wt, base)
    outside = Enum.reject(files, &Tickets.path_owned?(&1, ticket.owned))

    protected =
      case get_in(cfg, ["verify", "protectedPathsRegex"]) do
        nil -> []
        re -> Enum.filter(files, &Regex.match?(Regex.compile!(re), &1))
      end

    timeout = cfg["checkTimeoutMs"] || 600_000
    run_cmd = fn cmd ->
      t0 = System.monotonic_time(:millisecond)
      r = Sh.sh(cmd, cwd: wt, timeout: timeout, label: "verify #{ticket.id}")
      %{cmd: cmd, code: r.code, ms: System.monotonic_time(:millisecond) - t0, output: String.slice(String.trim(r.out <> r.err), -2000, 2000)}
    end

    # Repo-level hooks around the checks (start and stop the app, say); afterChecks always runs.
    # The ticket's own checks run first, then the repository-wide checks every ticket must pass.
    tv = cfg["verify"] || %{}
    before = Enum.map(tv["beforeChecks"] || [], run_cmd)
    hook_failed = Enum.reject(before, &(&1.code == 0))
    results = if hook_failed == [], do: Enum.map(ticket.checks ++ (tv["repoChecks"] || []), run_cmd), else: []
    Enum.each(tv["afterChecks"] || [], run_cmd)
    results = hook_failed ++ results

    problems =
      Enum.reject(
        [
          if(Git.dirty?(wt), do: "uncommitted changes in the worktree"),
          if(Git.commits_ahead(wt, base) == 0, do: "no commits ahead of #{base}; a ticket that changes no tracked file records its work with `git commit --allow-empty`"),
          if(outside != [], do: "changed paths outside owned paths: #{Enum.join(outside, ", ")}"),
          if(protected != [], do: "protected paths modified: #{Enum.join(protected, ", ")}")
        ] ++ Enum.map(hook_failed, &"verify.beforeChecks failed (exit #{&1.code}): #{&1.cmd}") ++
          Enum.map(Enum.reject(results -- hook_failed, &(&1.code == 0)), &"check failed (exit #{&1.code}): #{&1.cmd}"),
        &is_nil/1
      )

    %{ok: problems == [], problems: problems, results: results, files: files}
  end

  def describe(v) do
    Enum.map_join(v.problems, "\n", &"- #{&1}") <>
      "\n" <> Enum.map_join(Enum.reject(v.results, &(&1.code == 0)), "\n", &"$ #{&1.cmd}\n#{&1.output}")
  end
end
