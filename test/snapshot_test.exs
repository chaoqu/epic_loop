defmodule EpicLoop.SnapshotTest do
  use ExUnit.Case, async: true
  alias EpicLoop.Snapshot

  defp wt(path, branch, linked \\ true), do: %{"path" => path, "branch" => branch, "is_linked_worktree" => linked, "open_workspace_id" => nil}

  test "worktrees are sorted into integration, ticket and stray the way the loop decides it" do
    wts = [wt("/repo", "main", false), wt("/int", "epic/e1"), wt("/t1", "ticket/e1.1"), wt("/t9", "ticket/other.9"), wt("/byreport", "scratch/a"), wt("/stray", "scratch/b"), wt("/unrelated", "feature/x")]
    descends? = &(&1 in ["/byreport", "/stray", "/t9"])
    reported = fn p -> if p == "/byreport", do: "e1.2" end
    ids = MapSet.new(["e1.1", "e1.2"])

    assert Snapshot.classify(wts, "epic/e1", ids, descends?, reported) |> Enum.map(&{&1.path, &1.role, &1.ticket}) ==
             [{"/int", "integration", nil}, {"/t1", "ticket", "e1.1"}, {"/t9", "stray", nil}, {"/byreport", "ticket", "e1.2"}, {"/stray", "stray", nil}]
  end

  test "git is asked only about worktrees the branch name does not settle" do
    wts = [wt("/int", "epic/e1"), wt("/t1", "ticket/e1.1")]
    assert length(Snapshot.classify(wts, "epic/e1", MapSet.new(["e1.1"]), fn _ -> flunk("asked git") end, fn _ -> flunk("read a report") end)) == 2
  end

  test "attention entries keep their timestamps, and delivery follows the byte count" do
    first = "\n## 2026-09-28T10:00:00Z e1.1 needs you\nWhich one?\n"
    text = first <> "\n## 2026-09-28T11:00:00Z epic landed\nepic/e1 is ready.\n"

    assert [%{ts: "2026-09-28T10:00:00Z", title: "e1.1 needs you", body: "Which one?", delivered: true}, %{title: "epic landed", delivered: false}] =
             Snapshot.attention_entries(text, byte_size(first))

    assert Enum.map(Snapshot.attention_entries(text, byte_size(text)), & &1.delivered) == [true, true]
    assert Enum.map(Snapshot.attention_entries(text, nil), & &1.delivered) == [nil, nil]
    # A count past the end means the file was replaced: nothing in it has been delivered.
    assert Enum.map(Snapshot.attention_entries(text, byte_size(text) + 10), & &1.delivered) == [false, false]
    assert Snapshot.attention_entries("", 0) == []
  end

  test "log lines parse into entries, and a line without a timestamp continues the one before" do
    text = "stray first line\n2026-09-28T10:00:00.1Z [land] epic e1 complete\n a.txt | 1 +\n2026-09-28T10:00:01Z [w-e1-1] report: done {\"checks\":1}\n"

    assert Snapshot.log_entries(text) == [
             %{ts: "2026-09-28T10:00:00.1Z", scope: "land", msg: "epic e1 complete\n a.txt | 1 +"},
             %{ts: "2026-09-28T10:00:01Z", scope: "w-e1-1", msg: "report: done {\"checks\":1}"}
           ]
  end

  defp st(fields), do: Snapshot.ticket_state(Map.merge(%{status: "open", close_reason: nil, open_deps: [], problems: [], ready: false, worker: nil, merging: false, answer: nil, run: true}, fields))

  test "a ticket's state comes from br, refined by its worker as board.json has it" do
    assert st(%{status: "closed", close_reason: "Completed: abc fast-forwarded into epic/e1"}) == {"merged", "merged"}
    assert st(%{status: "closed", close_reason: "duplicate"}) == {"closed", "closed"}
    assert st(%{status: "blocked"}) == {"needs_you", "needs you"}
    assert st(%{status: "blocked", answer: "yes"}) == {"answered", "answer queued"}
    assert st(%{status: "in_progress", worker: %{"phase" => "running"}}) == {"working", "working"}
    assert st(%{status: "in_progress", worker: %{"phase" => "starting"}}) == {"working", "starting"}
    assert st(%{status: "in_progress", worker: %{"phase" => "merging"}, merging: true}) == {"merging", "merging"}
    assert st(%{status: "in_progress", worker: %{"phase" => "merging"}}) == {"queued", "in merge queue"}
    assert st(%{status: "in_progress", worker: %{"phase" => "pending_merge"}}) == {"queued", "merge deferred"}
    assert st(%{status: "in_progress"}) == {"orphan", "no worker yet"}
    assert st(%{status: "in_progress", run: false}) == {"orphan", "in progress, no run"}
    assert st(%{open_deps: [%{id: "e1.1"}], problems: ["no owned_paths in design"]}) == {"waiting", "waiting on deps"}
    assert st(%{problems: ["no owned_paths in design"], ready: true}) == {"incomplete", "incomplete"}
    assert st(%{ready: true}) == {"ready", "ready"}
    assert st(%{status: "deferred"}) == {"open", "deferred"}
  end

  test "the run state comes from the lock's holder and the board file it writes" do
    now = 1_000_000
    fresh = %{"os_pid" => "42", "written_at" => now - 1_000}
    assert Snapshot.run_state("42", fresh, false, false, now) == "running"
    assert Snapshot.run_state("42", fresh, true, false, now) == "stopping"
    assert Snapshot.run_state("42", %{fresh | "written_at" => now - 60_000}, false, false, now) == "unresponsive"
    # A board another pid wrote is the last run's: the new holder has not written one yet.
    assert Snapshot.run_state("43", fresh, false, false, now) == "starting"
    assert Snapshot.run_state("42", nil, false, false, now) == "starting"
    assert Snapshot.run_state(nil, Map.put(fresh, "ended", "stopped"), false, false, now) == "ended"
    assert Snapshot.run_state(nil, Map.put(fresh, "ended", "landed"), false, true, now) == "landed"
    assert Snapshot.run_state(nil, fresh, false, false, now) == "died"
    assert Snapshot.run_state(nil, nil, false, false, now) == "stopped"
  end

  test "a lane names what does not line up" do
    t = %{status: "in_progress"}
    w = %{"phase" => "running", "agent_name" => "w-e1-1", "wt" => "/t1"}
    agent = %{role: "worker", status: "working"}
    assert Snapshot.lane_issues(t, w, agent, %{path: "/t1"}, true, true) == []
    assert [m] = Snapshot.lane_issues(t, w, nil, %{path: "/t1"}, true, true)
    assert m =~ "no agent named w-e1-1"
    assert Snapshot.lane_issues(t, nil, nil, %{path: "/t1"}, true, true) == ["no worker process; the next pass adopts it"]
    assert Snapshot.lane_issues(%{status: "blocked"}, nil, agent, nil, false, false) == ["agent open with no run; the next run adopts it"]
    # A run without a board (an older epic_loop) is still a run: its agents are not left over.
    assert Snapshot.lane_issues(%{status: "blocked"}, nil, agent, nil, false, true) == []
    assert Snapshot.lane_issues(%{status: "closed"}, nil, %{agent | status: "blocked"}, nil, false, false) == ["the agent shows a dialog", "the agent is still open after the ticket closed"]
    assert Snapshot.lane_issues(t, w, agent, nil, true, true) == ["herdr no longer lists the worktree /t1"]
  end

  test "agents belong to the epic by name, or by working inside one of its worktrees" do
    agents = [
      %{"name" => "epic-e1", "cwd" => "/int", "agent_status" => "idle"},
      %{"name" => "w-e1-1", "cwd" => "/t1", "agent_status" => "working"},
      %{"name" => nil, "cwd" => "/t2/src", "agent_status" => "idle"},
      %{"name" => "someone", "cwd" => "/elsewhere", "agent_status" => "idle"},
      %{"name" => nil, "cwd" => "/t2-other", "agent_status" => "idle"}
    ]

    assert Snapshot.classify_agents(agents, "e1", ["e1.1", "e1.2"], [{"/int", nil}, {"/t2", "e1.2"}]) |> Enum.map(&{&1.name, &1.role, &1.ticket, &1.worktree}) ==
             [{"epic-e1", "integration", nil, "/int"}, {"w-e1-1", "worker", "e1.1", nil}, {nil, "unnamed", "e1.2", "/t2"}]
  end

  defp agent(name, role, ticket, pane, worktree \\ nil), do: %{name: name, role: role, ticket: ticket, pane_id: pane, worktree: worktree, status: "idle"}

  test "stray and orphaned agents are the ones no ticket row or integration section accounts for" do
    lanes = [%{ticket: "e1.1", agent: %{pane_id: "p1"}, worker: %{}}, %{ticket: "e1.2", agent: %{pane_id: "p2"}, worker: nil}, %{ticket: "e1.3", agent: %{pane_id: "p3"}, worker: nil}]
    status = %{"e1.1" => "in_progress", "e1.2" => "closed", "e1.3" => "blocked"}

    agents = [
      agent("epic-e1", "integration", nil, "p0", "/int"),
      agent("w-e1-1", "worker", "e1.1", "p1"),
      agent(nil, "unnamed", "e1.1", "p9", "/t1"),
      agent("w-e1-2", "worker", "e1.2", "p2"),
      agent("w-e1-3", "worker", "e1.3", "p3"),
      agent(nil, "unnamed", nil, "p7", "/int"),
      agent(nil, "unnamed", nil, "p8", "/stray")
    ]

    why = fn live -> Snapshot.stray_agents(agents, lanes, status, live, "/int") |> Enum.map(&{&1.pane_id, &1.why}) end

    assert why.(true) == [
             {"p9", "a second agent in the worktree of e1.1"},
             {"p2", "left open after e1.2 closed"},
             {"p3", "no worker process drives it"},
             {"p7", "an agent in the integration worktree besides its session"},
             {"p8", "an agent in the stray worktree /stray"}
           ]

    # Without a live run, a waiting ticket's agent is what the next run adopts, not an orphan.
    refute Enum.any?(why.(false), &(elem(&1, 0) == "p3"))
  end

  test "stray worktrees say why they match no ticket" do
    wts = [%{role: "ticket", branch: "ticket/e1.1"}, %{role: "stray", branch: "ticket/gone.4"}, %{role: "stray", branch: "scratch/a"}, %{role: "stray", branch: nil}, %{role: "integration", branch: "epic/e1"}]

    assert Snapshot.stray_worktrees(wts) |> Enum.map(& &1.why) == [
             "its branch names gone.4, which is not a ticket under the epic",
             "scratch/a descends from the epic marker but matches no ticket by branch name or report file",
             "detached, and descends from the epic marker"
           ]
  end

  test "ids sort by their numbers" do
    assert Enum.sort_by(["e1.10", "e1.2", "e1.1", "e1.2.1"], &Snapshot.natural/1) == ["e1.1", "e1.2", "e1.2.1", "e1.10"]
  end

  test "everything JSON cannot carry becomes a string" do
    term = %{{:cmd, 1} => "tuple key", pid: self(), mfa: {:a, :b, 1}, set: MapSet.new([1]), bad: <<"ok", 255>>, list: [:atom, nil, 2]}
    out = Snapshot.jsonable(term)
    assert is_binary(out.pid) and out.pid =~ "#PID"
    assert out.set == [1] and out.list == [:atom, nil, 2]
    assert String.valid?(out.bad)
    assert JSON.encode!(out) =~ "tuple key"
  end

  test "the view joins tickets, workers, agents and worktrees into lanes, and says what needs the person" do
    issue = fn id, status, extra -> Map.merge(%{"id" => id, "title" => "t #{id}", "status" => status, "issue_type" => "task", "design" => "owned_paths:\n- a/#{id}/\nmode: parallel", "acceptance_criteria" => "- [ ] `true`"}, extra) end

    ext = %{
      epic: %{"id" => "e1", "title" => "Epic"}, epic_branch: "epic/e1", marker: "abc",
      issues: [issue.("e1.1", "in_progress", %{}), issue.("e1.2", "blocked", %{}), issue.("e1.3", "open", %{"dependencies" => [%{"id" => "e1.1", "dependency_type" => "blocks"}]}), issue.("e1.4", "open", %{"design" => ""})],
      ready: MapSet.new(["e1.4"]),
      worktrees: [
        %{path: "/int", branch: "epic/e1", role: "integration", ticket: nil, dirty: 2},
        %{path: "/t1", branch: "ticket/e1.1", role: "ticket", ticket: "e1.1"},
        %{path: "/t2", branch: "ticket/e1.2", role: "ticket", ticket: "e1.2", last_report: %{"status" => "needs-human", "question" => "A or B?", "options" => ["A", "B"]}}
      ],
      agents: [%{name: "w-e1-1", role: "worker", ticket: "e1.1", status: "working", pane_id: "w2:p1"}],
      files: %{attention: [%{ts: "2026-09-28T10:00:00Z", title: "e1.2 needs you", body: "A or B?", delivered: false}], log: [], holder: "7"},
      collected_at: 0, collect_ms: 1, errors: []
    }

    board = %{
      "os_pid" => "7", "written_at" => EpicLoop.Board.now(), "run" => %{"started_at" => 0}, "coordinator" => %{"merging" => nil, "pass" => 3},
      "workers" => [%{"ticket" => "e1.1", "phase" => "running", "agent_name" => "w-e1-1", "wt" => "/t1"}], "commands" => [%{"ticket" => "e1.1", "line" => "git status"}], "tree" => [], "vm" => %{}
    }

    ctx = %{epic: "e1", cfg: %{"configPath" => "/c.json", "baseBranch" => "main", "dispatch" => %{"maxParallelWorkers" => 2}}, url: "http://127.0.0.1:1/e/e1"}
    v = Snapshot.view(ext, board, ctx)

    assert Enum.map(v.tickets, &{&1.id, &1.state}) == [{"e1.1", "working"}, {"e1.2", "needs_you"}, {"e1.3", "waiting"}, {"e1.4", "incomplete"}]
    assert v.run.state == "running" and v.run.live and v.loop["pass"] == 3
    assert [%{ticket: "e1.1", commands: [%{"line" => "git status"}]} | _] = v.lanes
    # A row for every ticket, in the tickets' order, with what it waits on.
    assert [%{ticket: "e1.1", agent: %{name: "w-e1-1"}, worktree: %{path: "/t1"}, issues: []}, %{ticket: "e1.2", worker: nil}, %{ticket: "e1.3", blocked_by: [%{id: "e1.1"}], worker: nil, agent: nil, worktree: nil}, %{ticket: "e1.4"}] = v.lanes
    assert [%{kind: "question", ticket: "e1.2", question: "A or B?", options: ["A", "B"], command: cmd}, %{kind: "dirty"}, %{kind: "incomplete", ticket: "e1.4"}] = v.needs_you
    assert cmd == ~s(epic_loop answer --epic e1 --config /c.json --ticket e1.2 --text "<your answer>")
    assert v.counts["total"] == 4
    assert JSON.encode!(Snapshot.jsonable(v)) =~ "A or B?"

    assert %{epic_id: "e1", needs: 3, in_flight: 1, run: %{state: "running"}, loop: %{"pass" => 3}} = Snapshot.summary(v)

    # The board of a run that is gone is not live: no worker refines a ticket, and it is kept as the last known.
    dead = Snapshot.view(%{ext | files: %{ext.files | holder: nil}}, board, ctx)
    assert dead.run.state == "died" and dead.loop == nil and dead.processes == nil and dead.last["pass"] == 3
    assert hd(dead.tickets).state == "orphan"
    # A run that died needs the person first, with the command to start another.
    assert [%{kind: "run", heading: "The run died", command: "epic_loop run --epic e1 --config /c.json", body: body} | _] = dead.needs_you
    assert body =~ "It was at pass 3."
    # The attention entry about the open question is open.
    assert [%{title: "e1.2 needs you", status: "open"}] = v.attention
  end

  test "an attention entry is open while Needs you shows what it reported, and only the newest about a thing" do
    e = fn title -> %{title: title, ts: "t", body: "", delivered: true} end
    newest_first = [e.("e1.5 needs you"), e.("e1.8 cannot be dispatched"), e.("epic landed"), e.("e1.5 escalated"), e.("stray epic worktree /s"), e.("e1.4 needs you"), e.("something else")]
    open = MapSet.new([{:ticket, "e1.5"}, {:stray, "/s"}])

    assert Snapshot.attention_history(newest_first, open) |> Enum.map(&{&1.title, &1.status}) == [
             {"e1.5 needs you", "open"},
             {"e1.8 cannot be dispatched", "resolved"},
             {"epic landed", "resolved"},
             {"e1.5 escalated", "resolved"},
             {"stray epic worktree /s", "open"},
             {"e1.4 needs you", "resolved"},
             {"something else", nil}
           ]
  end

  test "an answer resolves the ticket's older question and carries no delivery" do
    e = fn title -> %{title: title, ts: "t", body: "", delivered: true} end
    newest_first = [e.("e1.6 needs you"), e.("e1.6 answered by the integration session"), e.("e1.6 needs you"), e.("e1.7 answered from the plan")]
    open = MapSet.new([{:ticket, "e1.6"}])

    assert Snapshot.attention_history(newest_first, open) |> Enum.map(&{&1.title, &1.status, &1.delivered}) == [
             {"e1.6 needs you", "open", true},
             {"e1.6 answered by the integration session", nil, nil},
             {"e1.6 needs you", "resolved", true},
             {"e1.7 answered from the plan", nil, nil}
           ]

    # An answer newer than the question resolves it, even while Needs you shows the ticket.
    assert Snapshot.attention_history([e.("e1.6 answered by the person"), e.("e1.6 needs you")], open) |> Enum.map(& &1.status) == [nil, "resolved"]
  end
end
