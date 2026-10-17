defmodule EpicLoop.Timing do
  @moduledoc """
  How long each stage of an epic took: one JSON object per line in `timings/<epic>.jsonl` in the state
  folder (`$XDG_STATE_HOME/epic_loop/`, else `~/.local/state/epic_loop/`). It is the one file the loop
  keeps outside the worktrees, so the record outlives the epic's cleanup.

  A line is written when a stage ends, with its `start` and its length `ms`:

  - a ticket's stages, from its worker: `setup`, `implement`, `fix` (after a failure, a review
    or a rebase conflict was handed back), `human` (waiting on an answer), and `merge` (from asking to
    merge until the coordinator decides);
  - within `merge`, the coordinator's: `queue`, `rebase`, `verify`, `review` and `merge-checks`;
  - the epic's: `integrated-review`, `land`, and `run`, one per run of the loop;
  - `agent`: one per Claude session of a ticket, written when the ticket merges, with where its time
    went (see `EpicLoop.Transcript`) and, under `usage`, its tokens and what filled its context, with
    the twenty tools and files that filled the most (see `EpicLoop.Usage`). A later line for the same
    session replaces an earlier one.

  `epic_loop times` prints them (see `EpicLoop.Times`). A line that cannot be written is skipped; timing
  never stops the loop.
  """
  alias EpicLoop.{Epics, Log, Sh, Transcript, Usage}

  def file(epic), do: Path.join([Epics.root(), "timings", Epics.slug(epic) <> ".jsonl"])
  def now, do: System.os_time(:millisecond)

  @doc "Record a stage of `ticket` (nil for the epic's own) that began at `start` and ends now."
  def span(epic, ticket, stage, start, fields \\ %{}), do: put(epic, Map.merge(%{ticket: ticket, stage: stage, start: start, ms: now() - start}, fields))

  @doc "Run `fun` and record it as a stage; `fields` turns its result into what the line keeps."
  def timed(epic, ticket, stage, fun, fields \\ fn _ -> %{} end) do
    t0 = now()
    r = fun.()
    span(epic, ticket, stage, t0, fields.(r))
    r
  end

  @doc """
  Record where the time of every Claude session in the ticket's worktree went. `check_commands` is the
  config's `timing.checkCommands`: a regex for the Bash commands that count as checks besides the
  usual build and test tools.
  """
  def agents(epic, ticket, wt, check_commands) do
    extra = if check_commands, do: Regex.compile!(check_commands)

    case Transcript.sessions(wt) do
      [] -> Log.info(ticket, "timing: no Claude transcripts under #{Transcript.dir(wt)}")
      files ->
        for f <- files, r = Transcript.analyze(f, extra), r != nil do
          put(epic, Map.merge(r, %{ticket: ticket, stage: "agent", usage: Usage.summary(Usage.read(f, wt, extra), 20)}))
        end
    end
  rescue
    e -> Log.info(ticket, "timing: transcripts not read: #{Exception.message(e)}")
  end

  def put(epic, rec) do
    f = file(epic)
    File.mkdir_p!(Path.dirname(f))
    File.write!(f, JSON.encode!(Map.put(rec, :epic, epic)) <> "\n", [:append])
  rescue
    _ -> :ok
  end

  @doc "Every line recorded for the epic, oldest first, with string keys."
  def read(epic) do
    case File.read(file(epic)) do
      {:ok, raw} -> raw |> String.split("\n", trim: true) |> Enum.map(&Sh.decode/1) |> Enum.filter(&is_map/1)
      _ -> []
    end
  end
end
