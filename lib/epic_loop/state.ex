defmodule EpicLoop.State do
  @moduledoc """
  The loop's files. Every one lives in the artifact folder of a worktree, so removing an epic's worktrees
  removes everything the loop wrote. The integration worktree holds the epic's files: the log,
  `attention.md` (what needs the person, and every answer) and how much of it the integration session
  has been given, the stop file, the run lock, the integrated review round count and the run's live
  state for the dashboard. Each ticket worktree holds that ticket's files next to its brief and
  reports: an answer waiting for the worker, and the worker's counters.
  """
  alias EpicLoop.{Artifact, Log, Sh}

  # ---------------------------------------------------------------- the epic, in the integration worktree
  def log_file(int_wt), do: Path.join(Artifact.dir(int_wt), "loop.log")
  def attention_file(int_wt), do: Path.join(Artifact.dir(int_wt), "attention.md")
  def delivered_file(int_wt), do: Path.join(Artifact.dir(int_wt), "attention.delivered")
  def stop_file(int_wt), do: Path.join(Artifact.dir(int_wt), "stop")
  def lock_file(int_wt), do: Path.join(Artifact.dir(int_wt), "run.lock")
  def rounds_file(int_wt), do: Path.join(Artifact.dir(int_wt), "review-rounds")
  def board_file(int_wt), do: Path.join(Artifact.dir(int_wt), "board.json")

  def attention(int_wt, title, body) do
    Artifact.ensure_dir(int_wt)
    f = attention_file(int_wt)
    File.write!(f, "\n## #{DateTime.utc_now() |> DateTime.to_iso8601()} #{title}\n#{body}\n", [:append])
    Log.info("ATTENTION", "#{title} (see #{f})")
  end

  @doc """
  Record an answer to a ticket's question or escalation in `attention.md`, where the attention history
  keeps it. `by` is `:person`, `:session` (the integration session, on its own recommendation) or
  `:plan` (the loop, because the epic, the ticket and the rules settle the question). Options: `why`,
  and `question` for an answer the question of which never reached `attention.md`. Delivery neither
  notifies about an answer nor gives it to the session (see `EpicLoop.Attention`).
  """
  def answered(int_wt, ticket, by, text, opts \\ []) do
    title =
      case by do
        :person -> "#{ticket} answered by the person"
        :session -> "#{ticket} answered by the integration session"
        :plan -> "#{ticket} answered from the plan"
      end

    lines = [text, opts[:question] && "Question: #{opts[:question]}", opts[:why] && "Why: #{opts[:why]}"]
    attention(int_wt, title, lines |> Enum.filter(&(&1 not in [nil, ""])) |> Enum.join("\n\n"))
  end

  def review_rounds(int_wt) do
    case File.read(rounds_file(int_wt)) do
      {:ok, s} -> String.trim(s) |> Integer.parse() |> case do {n, _} -> n; _ -> 0 end
      _ -> 0
    end
  end

  def put_review_rounds(int_wt, n), do: (Artifact.ensure_dir(int_wt); File.write!(rounds_file(int_wt), Integer.to_string(n)))

  # ---------------------------------------------------------------- the run lock
  @doc """
  Take the epic's run lock: :ok, or {:error, pid} while a live process holds it. The lock file holds the
  OS pid of the run. A pid whose process is gone, or whose command line no longer contains `match`, is
  stale and the lock is taken over. The file is created exclusively, so two runs starting together
  cannot both take it.
  """
  def acquire_lock(int_wt, match \\ "epic_loop") do
    Artifact.ensure_dir(int_wt)
    take_lock(int_wt, match, 1)
  end

  defp take_lock(int_wt, match, retries) do
    f = lock_file(int_wt)

    case File.open(f, [:write, :exclusive]) do
      {:ok, io} ->
        IO.write(io, System.pid())
        File.close(io)
        :ok

      {:error, :eexist} ->
        case holder(int_wt, match) do
          nil when retries > 0 -> File.rm(f); take_lock(int_wt, match, retries - 1)
          nil -> {:error, "unknown"}
          pid -> {:error, pid}
        end
    end
  end

  @doc "The pid of the live process holding the epic's run lock, or nil."
  def holder(int_wt, match \\ "epic_loop") do
    with {:ok, raw} <- File.read(lock_file(int_wt)),
         pid when pid != "" <- String.trim(raw),
         true <- alive?(pid, match) do
      pid
    else
      _ -> nil
    end
  end

  @doc "Remove the run lock when this process holds it; a lock another run took over is left alone."
  def release_lock(int_wt) do
    f = lock_file(int_wt)
    if match?({:ok, _}, File.read(f)) and String.trim(File.read!(f)) == System.pid(), do: File.rm(f)
    :ok
  end

  @doc "Whether the OS process `pid` lives and its command line contains `match`."
  def alive?(pid, match) do
    String.match?(pid, ~r/^\d+$/) and
      (r = Sh.run("ps", ["-p", pid, "-o", "command="]); r.code == 0 and String.contains?(r.out, match))
  end

  # ---------------------------------------------------------------- a ticket, in its worktree
  def answer_file(wt), do: Path.join(Artifact.dir(wt), "answer")
  def counters_file(wt), do: Path.join(Artifact.dir(wt), "counters.json")

  @counter_keys [:attempt, :review_round, :stall_nudges, :no_report_nudges, :flaky_retry]
  def counter_keys, do: @counter_keys

  @doc "The worker counters saved in the ticket's worktree: a map of known keys only, or %{} when none."
  def load_counters(wt) do
    with {:ok, raw} <- File.read(counters_file(wt)), %{} = d <- Sh.decode(raw) do
      for {k, v} <- Enum.map(@counter_keys, &{&1, d[Atom.to_string(&1)]}), is_integer(v) or is_boolean(v), into: %{}, do: {k, v}
    else
      _ -> %{}
    end
  end

  @doc "Save the worker counters; written to a temp file and renamed, so a crash never leaves half a file."
  def save_counters(wt, counters) do
    Artifact.ensure_dir(wt)
    f = counters_file(wt)
    tmp = f <> ".tmp"
    File.write!(tmp, JSON.encode!(Map.take(counters, @counter_keys)))
    File.rename!(tmp, f)
  end
end
