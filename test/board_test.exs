defmodule EpicLoop.BoardTest do
  # The board is one named table, so these tests do not run alongside each other.
  use ExUnit.Case, async: false
  alias EpicLoop.{Board, Sh}

  test "without a board every call is a no-op, so commands outside a run never depend on one" do
    assert Board.put(:coordinator, %{pass: 1}) == :ok
    assert Board.get(:coordinator) == nil
    assert Board.delete(:coordinator) == :ok
    assert Board.all() == []
    assert Sh.run("true", []).code == 0
  end

  test "put merges into an entry, and delete removes it" do
    start_supervised!(Board)
    Board.put(:coordinator, %{pass: 1, activity: "dispatch"})
    Board.put(:coordinator, %{activity: nil, next_tick_at: 5})
    assert Board.get(:coordinator) == %{pass: 1, activity: nil, next_tick_at: 5}
    assert [{:coordinator, _}] = Board.all()
    Board.delete(:coordinator)
    assert Board.all() == []
  end

  test "a monotonic timestamp maps to wall-clock time" do
    ago = System.monotonic_time(:millisecond) - 60_000
    assert_in_delta Board.wall(ago), Board.now() - 60_000, 50
    assert Board.wall(nil) == nil
  end

  test "an external command is on the board while it runs, with its owner, label and OS pid, and gone after" do
    start_supervised!(Board)
    me = self()
    task = Task.async(fn -> send(me, :started); Sh.sh("sleep 1", label: "a check", cwd: System.tmp_dir!()) end)
    assert_receive :started

    entry =
      Enum.find_value(1..40, fn _ ->
        Process.sleep(25)
        Enum.find_value(Board.all(), fn {{:cmd, _}, c} -> c; _ -> nil end)
      end)

    assert %{line: "sleep 1", label: "a check", owner: owner, os_pid: pid, started_at: at} = entry
    assert owner == task.pid and is_integer(pid) and at <= Board.now()
    assert Task.await(task).code == 0
    assert Board.all() == []
  end
end
