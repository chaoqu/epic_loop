defmodule EpicLoop.TimingTest do
  # XDG_STATE_HOME and CLAUDE_CONFIG_DIR are process-wide, so these tests do not run alongside the others.
  use ExUnit.Case, async: false
  alias EpicLoop.{Brief, Timing, Times, Transcript}

  setup do
    dir = Path.join(System.tmp_dir!(), "epic-loop-timing-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    old = Map.new(["XDG_STATE_HOME", "CLAUDE_CONFIG_DIR"], &{&1, System.get_env(&1)})
    System.put_env("XDG_STATE_HOME", Path.join(dir, "state"))
    System.put_env("CLAUDE_CONFIG_DIR", Path.join(dir, "claude"))
    on_exit(fn -> Enum.each(old, fn {k, v} -> if(v, do: System.put_env(k, v), else: System.delete_env(k)) end); File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "a Bash command is classed by its programs, not by words in its arguments" do
    assert Transcript.bash_kind("cd web && ./gradlew --no-watch-fs :web:test 2>&1 | tail -20") == "check"
    assert Transcript.bash_kind(~s("$HOME/epic_loop/config/example/checks.sh" > /tmp/out 2>&1; echo "exit=$?")) == "check"
    assert Transcript.bash_kind("L=/tmp/x timeout 600 npm run test") == "check"
    assert Transcript.bash_kind(~s(cat "$HOME/epic_loop/config/example/checks.sh")) == "read"
    assert Transcript.bash_kind(~s(git grep -n "renderer" -- '*.gradle' | head)) == "read"
    assert Transcript.bash_kind(~s(grep -E "^== |checks.sh exit|BUILD" /tmp/log | tail -30)) == "read"
    assert Transcript.bash_kind("sed -n 1,80p web/Page.kt; grep -n make web/Makefile") == "read"
    assert Transcript.bash_kind("until grep -q '^exit=' /tmp/log; do sleep 10; done; tail -5 /tmp/log") == "wait"
    assert Transcript.bash_kind("nohup ./gradlew test > /tmp/log 2>&1 &\nsleep 1") == "check"
    assert Transcript.bash_kind("python3 - <<'EOF'\np='a.kt'\ns=open(p).read()\nopen(p,'w').write(s.replace('a','b'))\nEOF") == "write"
    assert Transcript.bash_kind("sed -i '' 's/a/b/' web/Page.kt") == "write"
    assert Transcript.bash_kind("python3 - <<'EOF'\nimport subprocess\nsubprocess.run(['make', 'test'])\nEOF") == "other"
    assert Transcript.bash_kind("git add -A && git commit -m 'web: page'") == "git"
    assert Transcript.bash_kind("dev-tools/render-diff.sh > /tmp/d", ~r/^\S*render-diff/) == "check"
    assert Transcript.bash_kind("dev-tools/render-diff.sh > /tmp/d") == "other"
  end

  # A session whose gaps are known: every second of its 480 lands in exactly one place.
  defp transcript(path) do
    t0 = ~U[2026-10-15 10:00:00.000Z]
    at = fn s -> DateTime.add(t0, round(s * 1000), :millisecond) |> DateTime.to_iso8601() end
    usage = %{"input_tokens" => 10, "cache_read_input_tokens" => 150_000, "cache_creation_input_tokens" => 5000}
    a = fn s, id, stop, block -> %{"type" => "assistant", "timestamp" => at.(s), "message" => %{"id" => id, "model" => "claude-opus-5-5", "stop_reason" => stop, "usage" => usage, "content" => [block]}} end
    use_ = fn id, name, input -> %{"type" => "tool_use", "id" => id, "name" => name, "input" => input} end
    result = fn s, id, extra -> Map.merge(%{"type" => "user", "timestamp" => at.(s), "message" => %{"content" => [%{"type" => "tool_result", "tool_use_id" => id, "content" => "ok"}]}}, extra) end

    lines = [
      %{"type" => "mode", "mode" => "normal"},
      %{"type" => "user", "timestamp" => at.(0), "message" => %{"content" => Brief.prompt_text()}},
      a.(2, "m1", "tool_use", %{"type" => "thinking", "thinking" => "..."}),
      a.(3, "m1", "tool_use", use_.("r1", "Read", %{"file_path" => "web/Page.kt"})),
      result.(3.5, "r1", %{}),
      a.(6, "m2", "tool_use", use_.("b1", "Bash", %{"command" => "./gradlew test"})),
      %{"type" => "assistant", "isSidechain" => true, "timestamp" => at.(30), "message" => %{"id" => "x", "content" => [%{"type" => "text", "text" => "subagent"}]}},
      result.(66, "b1", %{}),
      a.(70, "m3", "tool_use", use_.("b2", "Bash", %{"command" => ~s("$HOME/c/checks.sh"), "run_in_background" => true})),
      result.(70.1, "b2", %{"toolUseResult" => %{"backgroundTaskId" => "bk1"}}),
      a.(72, "m4", "end_turn", %{"type" => "text", "text" => "Waiting for the checks."}),
      %{"type" => "attachment", "timestamp" => at.(172), "attachment" => %{"type" => "queued_command", "prompt" => "<task-notification>\n<task-id>bk1</task-id>\n<tool-use-id>b2</tool-use-id>\n<status>completed</status>\n</task-notification>"}},
      a.(175, "m5", "tool_use", use_.("w1", "Write", %{"file_path" => ".agent_artifact/epic-loop/report.json", "content" => "{}"})),
      result.(175.2, "w1", %{"toolUseResult" => "Error: not a map"}),
      a.(177, "m6", "end_turn", %{"type" => "text", "text" => "Done."}),
      %{"type" => "user", "timestamp" => at.(477), "message" => %{"content" => "Code review found blockers in your change."}},
      a.(480, "m7", "end_turn", %{"type" => "text", "text" => "Fixed."})
    ]

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", &JSON.encode!/1) <> "\nnot json\n")
  end

  test "a session's time is split between thinking, each tool's model and run time, and idle", %{dir: dir} do
    f = Path.join(dir, "s1.jsonl")
    transcript(f)
    r = Transcript.analyze(f)

    assert %{session: "s1", role: "implementer", model: "claude-opus-5-5", ms: 480_000, idle_ms: 300_000, active_ms: 180_000, tool_calls: 4, prompts: 3, peak_context: 155_010} = r
    # 0-2 before the first block, 70.1-72 and 175.2-177 writing text, 477-480 answering the review
    assert r.think_ms == 8_700
    assert r.tools["Read"] == %{calls: 1, model_ms: 1000, run_ms: 500}
    # 60 s in the foreground, 0.1 s to launch in the background, 100 s waiting for its notification
    assert r.tools["Bash:check"] == %{calls: 2, model_ms: 6_500, run_ms: 160_100}
    assert r.tools["Write"] == %{calls: 1, model_ms: 3000, run_ms: 200}
    assert r.think_ms + Enum.sum(Enum.map(Map.values(r.tools), &(&1.model_ms + &1.run_ms))) + r.idle_ms == r.ms
  end

  test "a transcript with no exchange, or none at all, gives nothing", %{dir: dir} do
    f = Path.join(dir, "empty.jsonl")
    File.write!(f, ~s({"type":"mode"}\n))
    assert Transcript.analyze(f) == nil
    assert Transcript.analyze(Path.join(dir, "missing.jsonl")) == nil
  end

  test "Claude's folder for a worktree replaces every character but letters and digits" do
    assert Path.basename(Transcript.dir("/Users/me/.herdr/worktrees/acme/ticket-e1_2")) == "-Users-me--herdr-worktrees-acme-ticket-e1-2"
  end

  test "stages and agent sessions go to the epic's file, outside the worktrees", %{dir: dir} do
    wt = "/wt/ticket-e1-1"
    transcript(Path.join(Transcript.dir(wt), "s1.jsonl"))

    Timing.span("e1", "e1.1", "implement", Timing.now() - 5000, %{attempt: 1})
    assert Timing.timed("e1", "e1.1", "verify", fn -> %{ok: true} end, &%{ok: &1.ok}) == %{ok: true}
    Timing.agents("e1", "e1.1", wt, "render-diff")

    assert Timing.file("e1") == Path.join([dir, "state", "epic_loop", "timings", "e1.jsonl"])
    assert [%{"stage" => "implement", "ticket" => "e1.1", "epic" => "e1", "ms" => ms, "attempt" => 1}, %{"stage" => "verify", "ok" => true}, %{"stage" => "agent", "session" => "s1", "role" => "implementer", "tools" => %{"Read" => %{"calls" => 1}}}] = Timing.read("e1")
    assert ms >= 5000
    assert Timing.read("nothing") == []
  end

  test "the report sums the stages, groups the agents' tools, and keeps the latest record of a session" do
    t = 1_760_520_000_000
    agent = %{"epic" => "e1", "ticket" => "e1.1", "stage" => "agent", "session" => "s1", "role" => "implementer", "model" => "opus", "start" => t, "active_ms" => 100_000, "idle_ms" => 0, "think_ms" => 40_000, "tool_calls" => 3, "prompts" => 1, "peak_context" => 200_000,
      "tools" => %{"Read" => %{"calls" => 1, "model_ms" => 5000, "run_ms" => 5000}, "Bash:check" => %{"calls" => 1, "model_ms" => 2000, "run_ms" => 28_000}, "Edit" => %{"calls" => 1, "model_ms" => 20_000, "run_ms" => 0}}}

    records = [
      %{"epic" => "e1", "ticket" => "e1.1", "stage" => "setup", "start" => t, "ms" => 2000, "title" => "Add the page"},
      %{"epic" => "e1", "ticket" => "e1.1", "stage" => "implement", "start" => t + 2000, "ms" => 600_000, "attempt" => 1, "model" => "opus"},
      %{"epic" => "e1", "ticket" => "e1.1", "stage" => "merge", "start" => t + 602_000, "ms" => 240_000},
      %{"epic" => "e1", "ticket" => "e1.1", "stage" => "verify", "start" => t + 610_000, "ms" => 180_000, "ok" => true, "checks" => [%{"cmd" => "make test", "code" => 0, "ms" => 179_000}]},
      %{"epic" => "e1", "ticket" => "e1.1", "stage" => "review", "start" => t + 790_000, "ms" => 60_000, "round" => 1, "blockers" => 0, "warnings" => 2, "model" => "opus"},
      Map.put(agent, "active_ms", 1),
      agent,
      %{"epic" => "e1", "ticket" => nil, "stage" => "run", "start" => t, "ms" => 4_000_000, "result" => "landed"}
    ]

    epic = Times.report(records)
    assert epic =~ "Epic e1: 1 run(s), 1:06:40 running, last landed"
    assert epic =~ ~r/implement\s+10:00\s+71%/
    assert epic =~ ~r/fix\s+-\n/
    assert epic =~ ~r/merge\s+4:00\s+29%\s+queue 0:00 · rebase 0:00 · verify 3:00 · review 1:00/
    assert epic =~ "1 session(s): 1:40 working"
    assert epic =~ ~r/checks\s+0:30\s+30%\s+Bash:check 0:30 \(1\)/
    assert epic =~ ~r/writing\s+0:20\s+20%\s+Edit 0:20 \(1\)/

    one = Times.report(records, "e1.1")
    assert one =~ "Ticket e1.1: Add the page"
    assert one =~ ~r/verify\s+3:00\s+passed, make test 2:59/
    assert one =~ ~r/review\s+1:00\s+round 1, 0 blockers, 2 warnings, opus/
    assert one =~ "implementer s1  opus  1:40 working"
    assert Times.report(records, "e1.9") == "nothing recorded for e1.9\n"
    assert Times.report([]) == "nothing recorded yet\n"
  end

  test "lengths read as m:ss, or h:mm:ss from an hour" do
    assert Times.fmt(0) == "0:00"
    assert Times.fmt(61_999) == "1:01"
    assert Times.fmt(3_600_000 + 5000) == "1:00:05"
  end
end
