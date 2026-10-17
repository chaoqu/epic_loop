defmodule EpicLoop.BoardFileTest do
  use ExUnit.Case, async: false
  alias EpicLoop.{Board, BoardFile, State}

  setup do
    wt = Path.join(System.tmp_dir!(), "board-file-#{System.unique_integer([:positive])}")
    File.mkdir_p!(wt)
    on_exit(fn -> File.rm_rf!(wt) end)
    %{wt: wt}
  end

  defp read_when(wt, fun) do
    Enum.find_value(1..60, fn _ ->
      Process.sleep(50)
      with {:ok, raw} <- File.read(State.board_file(wt)), {:ok, d} <- JSON.decode(raw), true <- fun.(d), do: d, else: (_ -> nil)
    end) || flunk("board.json never showed what was expected")
  end

  test "the board is written every second with a heartbeat, and the last write records the end", %{wt: wt} do
    start_supervised!(Board)
    Board.put(:run, %{epic: "e1", coordinator: self(), started_at: 5})
    Board.put(:coordinator, %{pass: 7, merging: "e1.2"})
    Board.put({:worker, "e1.2"}, %{pid: self(), ticket: "e1.2", phase: :merging})
    start_supervised!({BoardFile, integration: wt})

    d = read_when(wt, &match?(%{"coordinator" => %{"pass" => 7}}, &1))
    assert %{"format" => 1, "os_pid" => pid, "written_at" => at, "run" => %{"epic" => "e1"}, "workers" => [%{"ticket" => "e1.2", "phase" => "merging", "pid" => "#PID" <> _}]} = d
    assert pid == System.pid() and d["ended"] == nil
    assert read_when(wt, &(&1["written_at"] > at))

    assert BoardFile.finish(wt, "stopped") == :ok
    assert %{"ended" => "stopped", "ended_at" => ended_at} = read_when(wt, &(&1["ended"] != nil))
    # A tick after the end keeps the record.
    assert %{"ended" => "stopped", "ended_at" => ^ended_at} = read_when(wt, &(&1["written_at"] > ended_at))
    refute File.exists?(State.board_file(wt) <> ".tmp")
  end

  test "without a writer, the end is still recorded", %{wt: wt} do
    assert BoardFile.finish(wt, "coordinator died: :boom") == :ok
    assert %{"ended" => "coordinator died: :boom", "run" => nil} = read_when(wt, &(&1["ended"] != nil))
  end
end
