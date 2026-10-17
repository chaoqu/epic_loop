defmodule EpicLoop.StateTest do
  use ExUnit.Case, async: true
  alias EpicLoop.State

  setup do
    wt = Path.join(System.tmp_dir!(), "epic-loop-state-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(wt)
    on_exit(fn -> File.rm_rf!(wt) end)
    %{wt: wt}
  end

  test "every file sits in the worktree's artifact folder", %{wt: wt} do
    dir = Path.join(wt, ".agent_artifact/epic-loop")

    for f <- [State.log_file(wt), State.attention_file(wt), State.delivered_file(wt), State.stop_file(wt), State.lock_file(wt), State.rounds_file(wt), State.board_file(wt), State.answer_file(wt), State.counters_file(wt)] do
      assert Path.dirname(f) == dir
    end
  end

  test "attention appends entries and review rounds round-trip", %{wt: wt} do
    State.attention(wt, "first", "body one")
    State.attention(wt, "second", "body two")
    text = File.read!(State.attention_file(wt))
    assert text =~ "first" and text =~ "second"
    assert State.review_rounds(wt) == 0
    State.put_review_rounds(wt, 2)
    assert State.review_rounds(wt) == 2
  end

  test "counters round-trip, keep false values, and ignore unknown keys and bad types", %{wt: wt} do
    assert State.load_counters(wt) == %{}
    State.save_counters(wt, %{attempt: 2, review_round: 1, stall_nudges: 0, no_report_nudges: 1, flaky_retry: false, phase: :running})
    assert State.load_counters(wt) == %{attempt: 2, review_round: 1, stall_nudges: 0, no_report_nudges: 1, flaky_retry: false}

    File.write!(State.counters_file(wt), ~s({"attempt": "3", "review_round": 4, "evil": 1}))
    assert State.load_counters(wt) == %{review_round: 4}

    File.write!(State.counters_file(wt), "not json")
    assert State.load_counters(wt) == %{}
  end

  # The test VM's command line contains "beam" but not "epic_loop", which lets these tests
  # choose whether it counts as a live run.
  test "the lock is taken once and refused while its holder lives", %{wt: wt} do
    assert State.acquire_lock(wt, "beam") == :ok
    assert File.read!(State.lock_file(wt)) == System.pid()
    assert State.holder(wt, "beam") == System.pid()
    assert State.acquire_lock(wt, "beam") == {:error, System.pid()}
  end

  test "a lock whose process is gone, or is not epic_loop, is stale and taken over", %{wt: wt} do
    File.mkdir_p!(Path.dirname(State.lock_file(wt)))
    File.write!(State.lock_file(wt), "99999999")
    assert State.holder(wt) == nil
    assert State.acquire_lock(wt) == :ok
    assert File.read!(State.lock_file(wt)) == System.pid()
    assert State.holder(wt) == nil
  end

  test "release removes only a lock this process holds", %{wt: wt} do
    File.mkdir_p!(Path.dirname(State.lock_file(wt)))
    File.write!(State.lock_file(wt), "12345")
    State.release_lock(wt)
    assert File.exists?(State.lock_file(wt))
    File.write!(State.lock_file(wt), System.pid())
    State.release_lock(wt)
    refute File.exists?(State.lock_file(wt))
  end
end
