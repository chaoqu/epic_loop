defmodule EpicLoop.Artifact do
  @moduledoc """
  The loop's folder in a worktree, `.agent_artifact/epic-loop/` at the worktree root. A ticket worktree
  keeps the worker's brief and reports there; `EpicLoop.State` names the loop's other files, which live
  in the same folder of the integration worktree or of a ticket worktree. `.agent_artifact/` is a folder each repository ignores in its own `.gitignore`
  (other agent tooling writes there too), so nothing here is ever committed; a worker that sweeps it into
  a commit fails verification for changing paths outside its owned paths. The loop does not edit any
  ignore file itself; it warns when the repository does not ignore the folder.
  """
  alias EpicLoop.{Log, Sh}

  @root ".agent_artifact"
  @dir Path.join(@root, "epic-loop")

  def root, do: @root
  def rel_brief, do: Path.join(@dir, "brief.md")
  def rel_report, do: Path.join(@dir, "report.json")
  def dir(wt), do: Path.join(wt, @dir)
  def brief(wt), do: Path.join(wt, rel_brief())
  def report(wt), do: Path.join(wt, rel_report())
  def archived_report(wt, attempt), do: Path.join(dir(wt), "report.#{attempt}.#{System.os_time(:millisecond)}.json")
  def ensure_dir(wt), do: File.mkdir_p!(dir(wt))

  @doc "Whether the repository ignores the folder. The folder is created first so a `dir/` pattern can match it."
  def ignored?(wt) do
    ensure_dir(wt)
    Sh.run("git", ["check-ignore", "-q", @root], cwd: wt).code == 0
  end

  @doc "ignored?/1, logging a warning under `who` when the repository does not ignore the folder."
  def warn_unless_ignored(wt, who) do
    if ignored?(wt) do
      true
    else
      Log.info(who, "WARNING: #{@root}/ is not ignored in #{wt}; add `#{@root}/` to the repository's .gitignore, or a worker may commit the loop's brief and report")
      false
    end
  end
end
