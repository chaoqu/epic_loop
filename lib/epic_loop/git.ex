defmodule EpicLoop.Git do
  @moduledoc "Git helpers. Every call names its cwd; the loop never relies on a checked-out branch."
  alias EpicLoop.Sh

  defp git(cwd, args, opts \\ []) do
    r = Sh.run("git", args, Keyword.merge([cwd: cwd], opts))
    Map.put(r, :out, String.trim(r.out))
  end

  def rev(cwd, ref) do
    case git(cwd, ["rev-parse", "--verify", "--quiet", ref]) do
      %{code: 0, out: out} when out != "" -> out
      _ -> nil
    end
  end

  @doc "The epic branch's marker commit, recorded in git config under the branch's own section; nil when unset."
  def marker(repo, name) do
    case git(repo, ["config", "--get", "branch.#{name}.marker"]) do
      %{code: 0, out: out} when out != "" -> String.trim(out)
      _ -> nil
    end
  end

  @doc """
  The integration branch starts with an empty marker commit that exists nowhere on the base branch.
  "Descends from the marker" is then a pure git fact for every worktree cut from the epic. The marker
  sha lives in branch config; a branch that predates the rule uses its first unique commit. Refs are
  written directly, so no checkout is touched.
  """
  def ensure_epic_branch(repo, name, base) do
    created =
      if rev(repo, "refs/heads/#{name}") do
        false
      else
        r = git(repo, ["branch", name, base])
        if r.code != 0, do: raise("git branch #{name} #{base}: #{r.err}")
        true
      end

    marker = marker(repo, name)

    marker =
      marker ||
        (fn ->
           unique = git(repo, ["rev-list", "--reverse", "#{base}..#{name}"]).out |> String.split("\n", trim: true)

           m =
             case unique do
               [first | _] ->
                 first

               [] ->
                 tip = rev(repo, name)
                 tree = git(repo, ["rev-parse", "#{tip}^{tree}"]).out
                 c = git(repo, ["commit-tree", tree, "-p", tip, "-m", "#{name}: integration base (empty marker commit)"])
                 if c.code != 0, do: raise("git commit-tree: #{c.err}")
                 u = git(repo, ["update-ref", "refs/heads/#{name}", c.out, tip])
                 if u.code != 0, do: raise("git update-ref #{name}: #{u.err}")
                 c.out
             end

           git(repo, ["config", "branch.#{name}.marker", m])
           m
         end).()

    %{created: created, marker: marker}
  end

  def descends_from?(cwd, ancestor, ref \\ "HEAD"), do: git(cwd, ["merge-base", "--is-ancestor", ancestor, ref]).code == 0

  def rebase(wt, onto) do
    r = git(wt, ["rebase", onto])

    if r.code == 0 do
      {:ok, nil}
    else
      git(wt, ["rebase", "--abort"])
      {:conflict, String.trim(r.out <> "\n" <> r.err)}
    end
  end

  def changed_files(wt, base), do: git(wt, ["diff", "--name-only", "#{base}...HEAD"]).out |> String.split("\n", trim: true)
  def commits_ahead(wt, base), do: git(wt, ["rev-list", "--count", "#{base}..HEAD"]).out |> String.to_integer()
  def dirty?(wt), do: git(wt, ["status", "--porcelain", "--untracked-files=no"]).out != ""

  @doc "Fast-forward the branch checked out in `wt` to `source`, updating its files. Refuses a non-ff."
  def ff_merge(wt, source) do
    r = git(wt, ["merge", "--ff-only", source])
    if r.code == 0, do: :ok, else: {:error, String.trim(r.out <> "\n" <> r.err)}
  end

  @doc "Roll the checkout in `wt` back to `sha`. Only ever used on the integration worktree, which nothing else edits."
  def reset_hard(wt, sha), do: git(wt, ["reset", "--hard", sha]).code == 0

  def head(cwd), do: rev(cwd, "HEAD")
  def log1(cwd, ref), do: git(cwd, ["log", "-1", "--format=%h %s", ref]).out
  def diff_stat(repo, base, tip), do: git(repo, ["diff", "--stat", "#{base}...#{tip}"]).out
  def diff(repo, base, tip), do: Sh.run("git", ["diff", "#{base}...#{tip}"], cwd: repo, timeout: 60_000).out
end
