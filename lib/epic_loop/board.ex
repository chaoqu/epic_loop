defmodule EpicLoop.Board do
  @moduledoc """
  What the run's processes are doing, for the dashboard. The coordinator, each worker and every external
  command write their current state into one public ETS table as they go, and `EpicLoop.BoardFile`
  writes the table to `board.json` every second without calling any of them: a worker waiting in the
  merge queue, or a coordinator running a forty-minute check, would not answer a call until it finished.

  Keys: `:run` (the run's fixed facts), `:coordinator` (the pass, the countdown, the merge in progress),
  `{:worker, ticket_id}` (one per worker process) and `{:cmd, ref}` (one per external command in flight).
  Each key has one writer, so a read-merge-write needs no lock. The process that owns the table does
  nothing else, so a crashing worker never takes the board with it. Every call is a no-op when the table
  does not exist (the other commands, the tests), so nothing in the loop depends on it.
  """
  use GenServer

  @table :epic_loop_board

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil), do: {:ok, :ets.new(@table, [:named_table, :public, :set, read_concurrency: true, write_concurrency: true])}

  @doc "Merge `fields` into the entry under `key`."
  def put(key, fields) do
    :ets.insert(@table, {key, Map.merge(get(key) || %{}, Map.new(fields))})
    :ok
  rescue
    ArgumentError -> :ok
  end

  def get(key) do
    case :ets.lookup(@table, key) do
      [{_, v}] -> v
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  def delete(key) do
    :ets.delete(@table, key)
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Every entry, as `{key, map}` pairs; [] when no board exists."
  def all do
    :ets.tab2list(@table)
  rescue
    ArgumentError -> []
  end

  @doc "Wall-clock milliseconds since the epoch; what the board stores, so the page can count down."
  def now, do: System.os_time(:millisecond)

  @doc "The wall-clock time of a monotonic timestamp, which is what the loop's processes keep."
  def wall(nil), do: nil
  def wall(mono), do: now() - (System.monotonic_time(:millisecond) - mono)
end
