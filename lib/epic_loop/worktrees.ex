defmodule EpicLoop.Worktrees do
  @moduledoc """
  Finding a ticket's worktree, for the worker that works in it and for `epic_loop answer`. Membership is
  a git fact: the worktree descends from the epic's marker commit. Identity is the `ticket/<id>` branch,
  then the ticket named in the worktree's report file. Location is never consulted.
  """
  alias EpicLoop.{Artifact, Git, Herdr, Sh}

  def branch(ticket_id), do: "ticket/#{ticket_id}"

  @doc "{worktree, how it was found} for the ticket, or nil. A nil `marker` skips the report-file match."
  def find_ticket(repo, epic_branch, marker, ticket_id) do
    list = Herdr.worktree_list(repo) |> Enum.filter(&(&1["is_linked_worktree"] and &1["branch"] not in [nil, epic_branch]))

    case Enum.find(list, &(&1["branch"] == branch(ticket_id))) do
      %{} = w ->
        {w, "branch name"}

      nil when marker == nil ->
        nil

      nil ->
        case Enum.find(list, &(Git.descends_from?(&1["path"], marker) and reports?(&1["path"], ticket_id))) do
          nil -> nil
          w -> {w, "report file"}
        end
    end
  end

  defp reports?(wt, ticket_id) do
    case File.read(Artifact.report(wt)) do
      {:ok, j} -> (Sh.decode(j) || %{})["ticket"] == ticket_id
      _ -> false
    end
  end
end
