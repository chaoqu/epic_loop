defmodule EpicLoop.AttentionTest do
  # A fake `herdr` first on PATH plays the integration session and records every call.
  use ExUnit.Case, async: false
  alias EpicLoop.{Attention, Integration, State}

  @fake ~S'''
  #!/bin/sh
  # One line per call: a multi-line prompt has its newlines turned into spaces.
  printf '%s' "$*" | tr '\n' ' ' >> "$FAKE_HERDR/calls"; echo >> "$FAKE_HERDR/calls"
  case "$1 $2" in
    "agent get")
      if [ ! -f "$FAKE_HERDR/status" ]; then
        echo '{"error":{"code":"agent_not_found","message":"not found"}}' >&2; exit 1
      fi
      focused=false; [ -f "$FAKE_HERDR/focused" ] && focused=true
      echo "{\"result\":{\"agent\":{\"agent_status\":\"$(cat "$FAKE_HERDR/status")\",\"focused\":$focused}}}" ;;
    "agent read") cat "$FAKE_HERDR/screen" ;;
    "agent prompt") echo '{"result":{}}' ;;
    "notification show") exit 0 ;;
  esac
  '''

  @epic "acme-e1"

  setup do
    dir = Path.join(System.tmp_dir!(), "fake-herdr-#{System.unique_integer([:positive])}")
    wt = Path.join(dir, "wt")
    File.mkdir_p!(wt)
    File.write!(Path.join(dir, "herdr"), @fake)
    File.chmod!(Path.join(dir, "herdr"), 0o755)
    File.write!(Path.join(dir, "calls"), "")
    File.write!(Path.join(dir, "screen"), "screen one")
    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    System.put_env("FAKE_HERDR", dir)
    on_exit(fn -> System.put_env("PATH", path); File.rm_rf!(dir) end)
    %{dir: dir, wt: wt}
  end

  defp calls(dir), do: dir |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)
  defp verbs(dir), do: calls(dir) |> Enum.map(&(&1 |> String.split() |> Enum.take(2) |> Enum.join(" ")))
  defp status(dir, st), do: File.write!(Path.join(dir, "status"), st)
  defp reset(dir), do: File.write!(Path.join(dir, "calls"), "")

  test "entries are the headings State.attention writes, with their bodies", %{wt: wt} do
    State.attention(wt, "t.1 needs you", "Which one?\nOptions: A | B")
    State.attention(wt, "t.2 escalated", "gave up")

    assert [%{title: "t.1 needs you", body: "Which one?\nOptions: A | B"}, %{title: "t.2 escalated", body: "gave up"}] =
             Attention.entries(File.read!(State.attention_file(wt)))
  end

  test "an idle session gets a new notice once, with the answer commands, and a notification fires", %{dir: dir, wt: wt} do
    status(dir, "idle")
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 cannot be dispatched", "- no owned_paths in design")
    a = Attention.deliver(a)

    assert verbs(dir) == ["notification show", "agent get", "agent prompt"]
    prompt = Enum.find(calls(dir), &String.starts_with?(&1, "agent prompt"))
    assert prompt =~ "agent prompt #{Integration.session_name(@epic)} "
    assert prompt =~ "epic_loop answer --epic #{@epic} --config /cfg/config.json --ticket <ticket-id> --by session"
    assert prompt =~ "--by person"
    assert prompt =~ "t.1 cannot be dispatched" and prompt =~ "no owned_paths in design"
    assert File.read!(State.delivered_file(wt)) == Integer.to_string(File.stat!(State.attention_file(wt)).size)

    reset(dir)
    Attention.deliver(a)
    assert calls(dir) == []
  end

  test "a busy or missing session holds the entries; it gets them once idle, with no second notification", %{dir: dir, wt: wt} do
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "epic landed", "epic/e1 is ready.")
    a = Attention.deliver(a)
    assert verbs(dir) == ["notification show", "agent get"]

    reset(dir)
    status(dir, "working")
    a = Attention.deliver(a)
    assert verbs(dir) == ["agent get"]

    reset(dir)
    status(dir, "idle")
    Attention.deliver(a)
    assert verbs(dir) == ["agent get", "agent prompt"]
  end

  test "a focused session gets the prompt only after its screen stays the same for a pass", %{dir: dir, wt: wt} do
    status(dir, "idle")
    File.touch!(Path.join(dir, "focused"))
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 needs you", "Which one?")

    a = Attention.deliver(a)
    refute "agent prompt" in verbs(dir)

    File.write!(Path.join(dir, "screen"), "screen two, the person typed")
    a = Attention.deliver(a)
    refute "agent prompt" in verbs(dir)

    Attention.deliver(a)
    assert "agent prompt" in verbs(dir)
  end

  test "a new run continues from the saved offset and never replays what came before it", %{dir: dir, wt: wt} do
    status(dir, "idle")
    State.attention(wt, "old entry", "from a run before delivery existed")
    a = Attention.new(wt, @epic, "/cfg/config.json")
    Attention.deliver(a)
    assert calls(dir) == []

    State.attention(wt, "t.1 needs you", "Which one?")
    Attention.deliver(Attention.new(wt, @epic, "/cfg/config.json"))
    prompt = Enum.find(calls(dir), &String.starts_with?(&1, "agent prompt"))
    assert prompt =~ "t.1 needs you"
    refute prompt =~ "old entry"
  end

  test "entries are questions, answers or notices by their titles" do
    assert Attention.kind("t.1 needs you") == :question
    assert Attention.kind("t.1 escalated") == :question
    assert Attention.kind("t.1 answered by the integration session") == :answer
    assert Attention.kind("t.1 answered by the person") == :answer
    assert Attention.kind("t.1 answered from the plan") == :answer
    assert Attention.kind("t.1 cannot be dispatched") == :notice
    assert Attention.kind("epic landed") == :notice
  end

  test "an answer is recorded with who gave it and why", %{wt: wt} do
    State.answered(wt, "t.1", :session, "A: fix the mocks here", why: "the five tickets after it need them")
    State.answered(wt, "t.2", :plan, "Use the shared helper", question: "Which helper?", why: "the ticket names it")

    assert [
             %{title: "t.1 answered by the integration session", body: "A: fix the mocks here\n\nWhy: the five tickets after it need them"},
             %{title: "t.2 answered from the plan", body: "Use the shared helper\n\nQuestion: Which helper?\n\nWhy: the ticket names it"}
           ] = Attention.entries(File.read!(State.attention_file(wt)))
  end

  test "a question the session answers itself never reaches the person", %{dir: dir, wt: wt} do
    status(dir, "idle")
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 needs you", "Which one?\nOptions: A | B")
    a = Attention.deliver(a)
    # Given to the session, with no notification.
    assert verbs(dir) == ["agent get", "agent get", "agent prompt"]

    reset(dir)
    State.answered(wt, "t.1", :session, "A", why: "it keeps the base green")
    status(dir, "done")
    a = Attention.deliver(a)
    # The answer is neither notified nor given back to the session.
    assert calls(dir) == []

    Attention.deliver(a)
    assert calls(dir) == []
  end

  test "a question the session leaves to the person is notified once its turn ends", %{dir: dir, wt: wt} do
    status(dir, "idle")
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 needs you", "Which one?\nOptions: A | B")
    a = Attention.deliver(a)
    refute "notification show" in verbs(dir)

    reset(dir)
    status(dir, "working")
    a = Attention.deliver(a)
    assert verbs(dir) == ["agent get"]

    reset(dir)
    status(dir, "done")
    a = Attention.deliver(a)
    assert verbs(dir) == ["agent get", "notification show"]
    assert Enum.find(calls(dir), &String.starts_with?(&1, "notification show")) =~ "epic_loop: t.1 needs you"

    reset(dir)
    Attention.deliver(a)
    assert calls(dir) == []
  end

  test "a question with no session to go to is notified at once", %{dir: dir, wt: wt} do
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 escalated", "gave up after 3 attempts")
    Attention.deliver(a)
    assert verbs(dir) == ["agent get", "notification show", "agent get"]
    refute "agent prompt" in verbs(dir)
  end

  test "a question answered before the session saw it is neither given nor notified", %{dir: dir, wt: wt} do
    status(dir, "idle")
    a = Attention.new(wt, @epic, "/cfg/config.json")
    State.attention(wt, "t.1 needs you", "Which one?")
    State.answered(wt, "t.1", :person, "B")
    Attention.deliver(a)
    assert calls(dir) == []
    assert File.read!(State.delivered_file(wt)) == Integer.to_string(File.stat!(State.attention_file(wt)).size)
  end
end
