defmodule EpicLoop.BoardFile do
  @moduledoc """
  The run's live state on disk, for the dashboard: `board.json` in the integration worktree's artifact
  folder, rewritten every second from `EpicLoop.Board` and the run's process info (`Snapshot.live/0`).
  The run never talks to a dashboard; a dashboard reads this file whenever one is running.

  `written_at` doubles as a heartbeat: a file that stops changing while the run's pid lives means the
  run's VM is stuck. When the run ends, a last write records how (`ended`, `ended_at`), so a dashboard
  can tell a run that stopped or landed from one that died, which leaves no such record. Every write goes
  to a temp file renamed into place, so a reader never sees half a file. A failed write is logged once
  and retried on the next tick; this process is a temporary child, so nothing that happens to it stops
  the run.
  """
  use GenServer, restart: :temporary
  alias EpicLoop.{Board, Log, Snapshot, State}

  @every 1_000
  @format 1

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    send(self(), :write)
    {:ok, %{file: State.board_file(opts[:integration]), ended: nil, failing: false}}
  end

  @doc """
  The last write, from the run as it ends: how (`landed`, `stopped`, `once`, or why the coordinator died)
  and when. Later ticks keep the record, so it is the last word even if one runs before the run stops.
  """
  def finish(int_wt, reason) do
    GenServer.call(__MODULE__, {:finish, reason}, 5_000)
  catch
    :exit, _ -> write(State.board_file(int_wt), %{ended: reason, ended_at: Board.now()})
  end

  @impl true
  def handle_call({:finish, reason}, _from, s) do
    s = tick(%{s | ended: %{ended: reason, ended_at: Board.now()}})
    {:reply, :ok, s}
  end

  @impl true
  def handle_info(:write, s) do
    s = tick(s)
    Process.send_after(self(), :write, @every)
    {:noreply, s}
  end

  defp tick(s) do
    case write(s.file, s.ended || %{}) do
      :ok ->
        %{s | failing: false}

      {:error, e} ->
        unless s.failing, do: Log.info("board", "cannot write #{s.file}: #{e}; retrying every second")
        %{s | failing: true}
    end
  end

  defp write(file, extra) do
    data = Snapshot.live() |> Map.merge(%{format: @format, written_at: Board.now(), os_pid: System.pid()}) |> Map.merge(extra)
    File.mkdir_p!(Path.dirname(file))
    tmp = file <> ".tmp"
    File.write!(tmp, JSON.encode!(Snapshot.jsonable(data)))
    File.rename!(tmp, file)
    :ok
  rescue
    e -> {:error, Exception.message(e)}
  end
end
