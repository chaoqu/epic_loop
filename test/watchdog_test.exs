defmodule EpicLoop.WatchdogTest do
  # A fake `herdr` first on PATH answers like the real one and records every call.
  use ExUnit.Case, async: false
  alias EpicLoop.{Herdr, Session, Worker}

  @fake ~S'''
  #!/bin/sh
  echo "$*" >> "$FAKE_HERDR/calls"
  case "$1 $2" in
    "agent read")
      case "$*" in
        *recent-unwrapped*)
          if [ -f "$FAKE_HERDR/working" ]; then
            echo '{"error":{"code":"agent_not_idle","message":"use --source visible"}}' >&2; exit 1
          fi
          echo "scrollback text" ;;
        *visible*) echo "visible screen" ;;
      esac ;;
    "agent send-keys") exit 0 ;;
    "agent wait") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    "agent prompt")
      case "$*" in *"/exit"*) [ -f "$FAKE_HERDR/stubborn" ] || touch "$FAKE_HERDR/exited" ;; esac
      echo '{"result":{}}' ;;
    "agent list")
      if [ -f "$FAKE_HERDR/exited" ]; then echo '{"result":{"agents":[]}}'
      else echo '{"result":{"agents":[{"name":"w-t-1","pane_id":"w9:p1"}]}}'; fi ;;
  esac
  '''

  setup do
    dir = Path.join(System.tmp_dir!(), "fake-herdr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "herdr"), @fake)
    File.chmod!(Path.join(dir, "herdr"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    System.put_env("FAKE_HERDR", dir)
    on_exit(fn -> System.put_env("PATH", path); File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp calls(dir), do: dir |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)

  test "an idle agent is read from its scrollback", %{dir: dir} do
    assert Herdr.agent_read("w-t-1", 40) == {:ok, "scrollback text\n"}
    assert length(calls(dir)) == 1
  end

  test "a working agent is read from its visible screen instead of coming back empty", %{dir: dir} do
    File.touch!(Path.join(dir, "working"))
    assert Herdr.agent_read("w-t-1", 40) == {:ok, "visible screen\n"}
    assert [first, second] = calls(dir)
    assert first =~ "recent-unwrapped"
    assert second =~ "--source visible"
  end

  test "no evidence and quiet working agents are left alone; the rest is judged" do
    assert Worker.stall_plan("working", "turn cap", "") == :wait
    assert Worker.stall_plan("unknown", "silence", nil) == :wait
    assert Worker.stall_plan("working", "silence", "running tests") == :wait
    assert Worker.stall_plan("working", "turn cap", "running tests") == :judge
    assert Worker.stall_plan("unknown", "silence", "some screen") == :judge
  end

  test "a waiting worker takes an answer first, then a report once its agent has stopped" do
    assert Worker.waiting_plan(true, true, "working") == :answer
    assert Worker.waiting_plan(false, true, "idle") == :report
    assert Worker.waiting_plan(false, true, "gone") == :report
    assert Worker.waiting_plan(false, true, "working") == :wait
    assert Worker.waiting_plan(false, true, "blocked") == :wait
    assert Worker.waiting_plan(false, false, nil) == :wait
  end

  test "stop cancels the turn, waits for idle, exits Claude and waits for the name to go", %{dir: dir} do
    assert Session.stop("w-t-1", 2_000) == :ok
    verbs = calls(dir) |> Enum.map(&(&1 |> String.split() |> Enum.take(2) |> Enum.join(" ")))
    assert Enum.dedup(verbs) == ["agent list", "agent send-keys", "agent wait", "agent prompt", "agent list"]
    assert Enum.any?(calls(dir), &(&1 =~ "send-keys w-t-1 esc"))
    refute Enum.any?(calls(dir), &(&1 =~ "ctrl+c"))
  end

  test "stop reports an agent that does not exit instead of leaving the name taken", %{dir: dir} do
    File.touch!(Path.join(dir, "stubborn"))
    assert {:error, msg} = Session.stop("w-t-1", 1_200)
    assert msg =~ "still live"
  end

  test "stop on an agent that is already gone does nothing", %{dir: dir} do
    File.touch!(Path.join(dir, "exited"))
    assert Session.stop("w-t-1", 1_000) == :ok
    assert calls(dir) == ["agent list"]
  end
end
