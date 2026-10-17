defmodule EpicLoop.Coordinator do
  @moduledoc """
  One process per epic. Owns dispatch, the serial merge queue, the stray scan, the review round,
  landing, and delivering `attention.md` to the person. Holds no state that is not re-derivable from
  br, git and the worktrees; if it dies, a new one re-adopts the tickets it left. Workers are separate
  processes under EpicLoop.WorkerSup. It records how long each step of a merge took, and the epic's own
  stages (see `EpicLoop.Timing`).
  """
  use GenServer, restart: :temporary
  alias EpicLoop.{Attention, Board, Br, Git, Herdr, Integration, Log, Model, Session, State, Tickets, Timing, Verify, Worker, Worktrees}

  defstruct [:epic, :cfg, :epic_issue, :epic_branch, :marker, :actor, :once, :cli, :integration, :attention, :started_at, workers: %{}, monitors: %{}, flagged: MapSet.new(), incomplete: %{}, review_rounds: 0, dirty_flagged: false, passes: 0]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Serial merge queue: workers call this when their report says done. Blocks until decided."
  def merge(w), do: GenServer.call(__MODULE__, {:merge, w}, :infinity)

  @impl true
  def init(opts) do
    cfg = opts[:cfg]
    epic = opts[:epic]
    epic_issue = Br.show(epic) || raise("epic #{epic} not found")
    epic_branch = Integration.branch(cfg, epic)
    # `init` created the branch and the worktree; the loop only adopts them.
    integration = Integration.find(cfg, epic_branch) || raise("no integration worktree for #{epic_branch}; run `epic_loop init --epic #{epic}` first")
    %{marker: marker} = Git.ensure_epic_branch(cfg["repo"], epic_branch, cfg["baseBranch"])

    Log.info("loop", "#{epic_branch} in #{integration.path}; marker #{String.slice(marker, 0, 8)}; maxParallelWorkers=#{get_in(cfg, ["dispatch", "maxParallelWorkers"])}")

    state = %__MODULE__{
      epic: epic, cfg: cfg, epic_issue: epic_issue, epic_branch: epic_branch, marker: marker, integration: integration,
      actor: cfg["beadsActor"] || "epic-loop", once: opts[:once], cli: opts[:cli], started_at: Timing.now(),
      review_rounds: State.review_rounds(integration.path), attention: Attention.new(integration.path, epic, cfg["configPath"])
    }

    Board.put(:run, %{epic: epic, epic_branch: epic_branch, marker: marker, integration: integration.path, started_at: Board.now(), os_pid: System.pid(), coordinator: self()})
    send(self(), :tick)
    {:ok, state}
  end

  # ---------------------------------------------------------------- the pass
  @impl true
  def handle_info(:tick, s) do
    cond do
      File.exists?(State.stop_file(s.integration.path)) ->
        Log.info("loop", "kill switch: stop file present")
        doing("kill switch: stopping the workers")
        stop_workers(s)
        File.rm(State.stop_file(s.integration.path))
        finish(s, :stopped)

      true ->
        s = %{s | passes: s.passes + 1}
        board(%{pass: s.passes, pass_started_at: Board.now(), pass_finished_at: nil, next_tick_at: nil})
        s = s |> safely(&scan_strays/1, "stray scan") |> safely(&adopt_orphans/1, "adopt") |> safely(&dispatch/1, "dispatch")

        {done, s} = if map_size(s.workers) == 0, do: safely_check(s), else: {false, s}
        # Last, so what this pass wrote (the landing too) reaches the person on this pass.
        s = safely(s, &%{&1 | attention: Attention.deliver(&1.attention)}, "attention delivery")

        cond do
          done -> finish(s, :landed)
          s.once -> Log.info("loop", "once: exiting after one pass"); finish(s, :once)
          true -> Process.send_after(self(), :tick, s.cfg["pollIntervalMs"]); publish(s); {:noreply, s}
        end
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, s) do
    {ticket, monitors} = Map.pop(s.monitors, ref)
    workers = Map.reject(s.workers, fn {_, p} -> p == pid end)
    if ticket, do: Board.delete({:worker, ticket})
    if reason != :normal and ticket, do: Log.info("loop", "worker for #{ticket} exited: #{inspect(reason)}; it will be re-adopted from br")
    {:noreply, %{s | workers: workers, monitors: monitors}}
  end

  def handle_info(_, s), do: {:noreply, s}

  # The workers end first, so none sees its agent vanish and starts another. Then every agent of a
  # ticket in flight is closed, in parallel, so it stops working and its name is free for the next run.
  # An agent whose ticket waits on a human is left open: it is idle, the person may be steering it,
  # and the next run adopts it with its conversation.
  defp stop_workers(s) do
    phases = Map.new(s.workers, fn {id, pid} -> {id, Worker.phase(pid)} end)
    Enum.each(s.workers, fn {_, pid} -> DynamicSupervisor.terminate_child(EpicLoop.WorkerSup, pid) end)

    phases
    |> Enum.reject(fn {_, phase} -> phase == :awaiting_human end)
    |> Task.async_stream(fn {id, _} -> {id, Session.stop(Worker.agent_name(id))} end, timeout: 90_000, on_timeout: :kill_task, max_concurrency: max(map_size(phases), 1))
    |> Enum.each(fn
      {:ok, {id, {:error, e}}} -> Log.info("loop", "#{id}: could not close its agent: #{e}")
      {:exit, reason} -> Log.info("loop", "closing an agent timed out: #{inspect(reason)}")
      _ -> :ok
    end)
  end

  defp finish(s, reason) do
    Timing.span(s.epic, nil, "run", s.started_at, %{result: reason, passes: s.passes})
    if s.cli, do: send(s.cli, {:epic_loop_done, reason})
    {:stop, :normal, s}
  end

  # The dashboard's view of the coordinator (see EpicLoop.Board): the pass, the countdown to the next one,
  # and what it is doing now. A merge runs between passes, so while one runs the next pass is overdue.
  defp board(fields), do: Board.put(:coordinator, fields)
  defp doing(what), do: board(%{activity: what, activity_since: Board.now()})

  defp publish(s) do
    board(%{
      pass_finished_at: Board.now(), next_tick_at: Board.now() + s.cfg["pollIntervalMs"], activity: nil, activity_since: nil,
      review_rounds: s.review_rounds, strays: MapSet.to_list(s.flagged), dirty_flagged: s.dirty_flagged,
      incomplete: Map.new(s.incomplete, fn {id, e} -> {id, %{since: Board.wall(e.since), reported: e.reported}} end),
      attention_held: s.attention.held, attention_delivered: s.attention.delivered
    })
  end

  defp safely(s, fun, what) do
    doing(what)

    try do
      fun.(s)
    rescue
      e -> Log.info("loop", "#{what} error: #{Exception.message(e)}"); s
    end
  end

  defp safely_check(s) do
    doing("completion check")

    try do
      check_completion(s)
    rescue
      e -> Log.info("loop", "completion check error: #{Exception.message(e)}"); {false, s}
    end
  end

  # ---------------------------------------------------------------- dispatch
  @incomplete_grace_ms 300_000

  defp dispatch(s) do
    ready = Br.ready(s.epic) |> Enum.reject(&Map.has_key?(s.workers, &1["id"])) |> Enum.map(&(Br.show(&1["id"]) |> Tickets.parse()))
    {complete, incomplete} = Enum.split_with(ready, &(Tickets.validate(&1) == []))
    {seen, report} = track_incomplete(incomplete, s.incomplete, System.monotonic_time(:millisecond))

    Enum.each(report, fn t ->
      State.attention(s.integration.path, "#{t.id} cannot be dispatched", Enum.map_join(Tickets.validate(t), "\n", &"- #{&1}") <> "\nThe loop skips it until the fields are complete (design owned_paths, backticked acceptance commands), then dispatches it on the next pass. Nothing else needs to change.")
    end)

    Enum.reduce_while(complete, %{s | incomplete: seen}, fn t, s -> dispatch_one(t, s) end)
  end

  @doc """
  A ready ticket missing owned paths or acceptance checks is skipped, never blocked: `br create` cannot
  set those fields, so a ticket added while the loop runs is often seen between its create and its
  update, and it dispatches on the first pass that finds it complete. `seen` maps each incomplete
  ticket's id to when it was first found so and whether it was reported. One still incomplete after
  `grace` ms is reported once. Returns the new map, holding only the tickets incomplete now, and the
  tickets to report.
  """
  def track_incomplete(tickets, seen, now, grace \\ @incomplete_grace_ms) do
    Enum.reduce(tickets, {%{}, []}, fn t, {acc, report} ->
      e = Map.get(seen, t.id, %{since: now, reported: false})

      if not e.reported and now - e.since >= grace,
        do: {Map.put(acc, t.id, %{e | reported: true}), report ++ [t]},
        else: {Map.put(acc, t.id, e), report}
    end)
  end

  defp dispatch_one(t, s) do
    running = running_tickets(s)

    cond do
      map_size(s.workers) >= get_in(s.cfg, ["dispatch", "maxParallelWorkers"]) -> {:halt, s}
      Enum.any?(running, &(&1.mode == "serial")) -> {:halt, s}
      t.mode == "serial" and running != [] -> {:cont, s}
      Enum.any?(running, &Tickets.overlaps?(&1, t)) -> Log.info("loop", "#{t.id} waits: owned paths overlap a ticket in flight"); {:cont, s}
      not Br.claim(t.id, s.actor) -> Log.info("loop", "#{t.id}: claim refused"); {:cont, s}
      true -> {:cont, start_worker(t, :new, s)}
    end
  end

  defp running_tickets(s), do: s.workers |> Map.values() |> Enum.map(&Worker.ticket/1) |> Enum.reject(&is_nil/1)

  # Tickets left without a worker by a restart or a crashed worker process.
  defp adopt_orphans(s) do
    slots = get_in(s.cfg, ["dispatch", "maxParallelWorkers"]) - map_size(s.workers)
    has_worktree? = &(Worktrees.find_ticket(s.cfg["repo"], s.epic_branch, s.marker, &1) != nil)

    Br.descendants(s.epic)
    |> adoptable(s.workers, slots, has_worktree?)
    |> Enum.reduce(s, fn id, s -> start_worker(Br.show(id) |> Tickets.parse(), :adopt, s) end)
  end

  @doc """
  The ids of the tickets to adopt now: in-progress tickets, then blocked ones, which need a worker to
  read their answer. A blocked ticket counts only when it has a ticket worktree, since one blocked
  before it started is the person's to unblock. Adoption fills the free slots of
  `maxParallelWorkers` and no more; the rest wait for a later pass.
  """
  def adoptable(kids, workers, slots, has_worktree?) do
    free = Enum.reject(kids, &Map.has_key?(workers, &1["id"]))
    in_progress = for k <- free, k["status"] == "in_progress", do: k["id"]
    blocked = for k <- free, k["status"] == "blocked", do: k["id"]

    in_progress |> Stream.concat(Stream.filter(blocked, has_worktree?)) |> Enum.take(max(slots, 0))
  end

  defp start_worker(t, mode, s) do
    args = %{ticket: t, mode: mode, cfg: s.cfg, epic: s.epic, epic_issue: s.epic_issue, epic_branch: s.epic_branch, marker: s.marker, actor: s.actor, integration: s.integration.path}

    case DynamicSupervisor.start_child(EpicLoop.WorkerSup, {Worker, args}) do
      {:ok, pid} ->
        ref = Process.monitor(pid)
        %{s | workers: Map.put(s.workers, t.id, pid), monitors: Map.put(s.monitors, ref, t.id)}

      {:error, reason} ->
        Log.info("loop", "could not start worker for #{t.id}: #{inspect(reason)}")
        s
    end
  end

  # Worktrees cut from the epic that match no ticket are never merged; they are flagged once.
  defp scan_strays(s) do
    known = s.workers |> Map.values() |> Enum.map(&Worker.worktree/1) |> MapSet.new()

    Herdr.worktree_list(s.cfg["repo"])
    |> Enum.filter(&(&1["is_linked_worktree"] and &1["branch"] != s.epic_branch))
    |> Enum.reduce(s, fn w, s ->
      path = w["path"]

      if MapSet.member?(known, path) or MapSet.member?(s.flagged, path) or String.starts_with?(w["branch"] || "", "ticket/") or not Git.descends_from?(path, s.marker) do
        s
      else
        State.attention(s.integration.path, "stray epic worktree #{path}", "Branch #{w["branch"] || "(detached)"} descends from the epic marker but matches no ticket by name or report file. Nothing from it will merge. Inspect it, or add a .agent_artifact/epic-loop/report.json naming its ticket.")
        %{s | flagged: MapSet.put(s.flagged, path)}
      end
    end)
  end

  # ---------------------------------------------------------------- merge queue (serial by construction)
  @impl true
  def handle_call({:merge, w}, _from, s) do
    board(%{merging: w.ticket.id, merge_started_at: Board.now()})
    with {"merge", asked, _} <- w.stage, do: Timing.span(s.epic, w.ticket.id, "queue", asked)

    {reply, s} =
      try do
        verify_and_merge(w, s)
      rescue
        e -> {{:escalate, "merge step crashed: #{Exception.message(e)}"}, s}
      end

    board(%{merging: nil, merge_started_at: nil, activity: nil, activity_since: nil, last_merge: %{ticket: w.ticket.id, result: elem(reply, 0), at: Board.now()}})
    {:reply, reply, s}
  end

  # The integration worktree is shared with the person planning in it. Uncommitted tracked changes
  # there would break the fast-forward or be destroyed by a rollback, so nothing merges until it is
  # clean; the worker keeps its report and asks again next pass.
  defp verify_and_merge(w, s) do
    int = s.integration.path

    if Git.dirty?(int) do
      s =
        if s.dirty_flagged do
          s
        else
          State.attention(s.integration.path, "integration worktree has uncommitted changes", "#{int} has uncommitted tracked changes, so no ticket merges until it is clean. Commit or stash them in the integration session; the loop retries every pass.")
          %{s | dirty_flagged: true}
        end

      Log.info(w.agent_name, "integration worktree dirty; merge deferred")
      {{:retry_later, %{review_round: w.review_round}}, s}
    else
      rebase_verify_review_merge(w, %{s | dirty_flagged: false})
    end
  end

  defp rebase_verify_review_merge(w, s) do
    cfg = s.cfg
    max_attempts = get_in(cfg, ["worker", "maxAttempts"])
    doing("merge #{w.ticket.id}: rebase onto #{s.epic_branch}")

    case Timing.timed(s.epic, w.ticket.id, "rebase", fn -> Git.rebase(w.wt, s.epic_branch) end, &%{result: elem(&1, 0)}) do
      {:conflict, output} ->
        Log.info(w.agent_name, "rebase conflict; handing back to the author")

        if w.attempt + 1 > max_attempts do
          {{:escalate, "rebase conflicts unresolved:\n#{String.slice(output, 0, 2000)}"}, s}
        else
          {{:handback, "rebase", "Your branch no longer rebases cleanly onto #{s.epic_branch}. Run `git rebase #{s.epic_branch}`, resolve every conflict touching only your owned paths, continue the rebase, rerun the acceptance checks, and write ./.agent_artifact/epic-loop/report.json again. Then stop.\n\n#{String.slice(output, 0, 3000)}", %{attempt: w.attempt + 1}}, s}
        end

      {:ok, _} ->
        doing("merge #{w.ticket.id}: verify")
        v = Timing.timed(s.epic, w.ticket.id, "verify", fn -> Verify.run(w.wt, w.ticket, s.epic_branch, cfg) end, &%{ok: &1.ok, checks: Enum.map(&1.results, fn r -> Map.take(r, [:cmd, :code, :ms]) end)})

        if v.ok do
          review_then_merge(w, v, s)
        else
          {{:verify_failed, Verify.describe(v)}, s}
        end
    end
  end

  defp review_then_merge(w, v, s) do
    cfg = s.cfg

    if get_in(cfg, ["review", "enabled"]) == false do
      do_merge(w, v, "per-ticket review off", s)
    else
      round = w.review_round + 1
      doing("merge #{w.ticket.id}: review round #{round}")

      case Timing.timed(s.epic, w.ticket.id, "review", fn -> review_ticket(w, round, s) end, &%{round: round, model: get_in(cfg, ["review", "model"]), blockers: &1 && length(&1.blockers), warnings: &1 && length(&1.warnings)}) do
        nil ->
          {{:escalate, "per-ticket reviewer returned no verdict; not merging unreviewed work"}, s}

        %{blockers: []} = rv ->
          do_merge(%{w | review_round: round}, v, "review round #{round}: 0 blockers, #{length(rv.warnings)} warnings", s)

        rv ->
          text = Enum.map_join(rv.blockers, "\n", fn f -> "- #{f["path"]}#{if f["line"], do: ":#{f["line"]}", else: ""} — #{f["summary"]} (rule: #{f["rule"]})#{if f["check"], do: "\n  check: #{f["check"]}", else: ""}" end)
          Br.add_notes(w.ticket.id, String.slice("review round #{round} blockers:\n#{text}", 0, 3000), s.actor)
          cap = get_in(cfg, ["review", "maxRounds"]) || 2

          if round >= cap do
            {{:escalate, "review blockers remain after #{round} rounds:\n#{text}"}, s}
          else
            Log.info(w.agent_name, "handing #{length(rv.blockers)} review blocker(s) back to the worker")
            {{:handback, "review", "Code review found blockers in your change. Fix each one inside your owned paths, rerun the acceptance checks, commit, and write ./.agent_artifact/epic-loop/report.json again. Then stop.\n\n#{text}", %{review_round: round}}, s}
          end
      end
    end
  end

  defp do_merge(w, v, review_note, s) do
    sha = Git.head(w.wt)
    int = s.integration.path
    prev = Git.head(int)
    doing("merge #{w.ticket.id}: fast-forward")

    case Git.ff_merge(int, w.branch) do
      {:error, out} ->
        Log.info(w.agent_name, "fast-forward refused, will rebase again next pass: #{out |> String.split("\n") |> hd()}")
        {{:retry_later, %{review_round: w.review_round}}, s}

      :ok ->
        # Second gate: the suite on the integrated code. A failure rolls the integration worktree back
        # to the previous tip and hands the ticket back; nothing else has built on the new tip yet.
        doing("merge #{w.ticket.id}: checks after merge")
        t0 = Timing.now()

        ran =
          (get_in(s.cfg, ["merge", "checksAfterMerge"]) || [])
          |> Enum.map(fn cmd -> c0 = Timing.now(); r = EpicLoop.Sh.sh(cmd, cwd: int, timeout: s.cfg["checkTimeoutMs"] || 600_000, label: "checksAfterMerge #{w.ticket.id}"); {cmd, r, Timing.now() - c0} end)

        failed = Enum.find_value(ran, fn {cmd, r, _} -> if r.code != 0, do: {cmd, r} end)
        if ran != [], do: Timing.span(s.epic, w.ticket.id, "merge-checks", t0, %{ok: failed == nil, checks: Enum.map(ran, fn {cmd, r, ms} -> %{cmd: cmd, code: r.code, ms: ms} end)})

        case failed do
          {cmd, r} ->
            doing("merge #{w.ticket.id}: roll back")
            Git.reset_hard(int, prev)
            Log.info(w.agent_name, "integration check failed after merge; rolled #{s.epic_branch} back to #{String.slice(prev, 0, 8)}")
            # The worktree is on the previous tip again; put whatever runs on it back (the dev server).
            Enum.each(get_in(s.cfg, ["merge", "afterRollback"]) || [], fn cmd -> r = EpicLoop.Sh.sh(cmd, cwd: int, timeout: s.cfg["checkTimeoutMs"] || 600_000); Log.info(w.agent_name, "merge.afterRollback: #{cmd} -> exit #{r.code}") end)
            {{:verify_failed, "integration check failed on #{s.epic_branch} after merging your change (rolled back): #{cmd}\n#{String.slice(String.trim(r.out <> r.err), -3000, 3000)}"}, s}

          nil ->
            Br.close(w.ticket.id, "Completed: #{String.slice(sha, 0, 8)} fast-forwarded into #{s.epic_branch}; #{length(w.ticket.checks)} acceptance checks passed; #{review_note}; integration check passed; files: #{Enum.join(v.files, ", ")}", s.actor)
            Log.info(w.agent_name, "merged #{String.slice(sha, 0, 8)} into #{s.epic_branch}; ticket closed")
            {{:merged, %{review_round: w.review_round}}, s}
        end
    end
  end

  defp review_ticket(w, round, s) do
    diff = Git.diff(w.wt, s.epic_branch, "HEAD")

    if String.trim(diff) == "" do
      %{blockers: [], warnings: [], findings: []}
    else
      rules = case get_in(s.cfg, ["review", "rulesFile"]), do: (nil -> ""; f -> File.read!(f))
      t = w.ticket

      prompt = """
      You are reviewing one ticket's change before it merges into an integration branch, with fresh eyes. You get the diff, the rules, and the ticket's stated requirements; you did not write this and you do not see the author's reasoning. Flag only correctness and requirement gaps against the rules. Something the ticket explicitly asks for, or that its acceptance checks require, is never a finding. Every finding cites one rule from the list and the path it applies to (line when visible in the diff). For a blocker, give a shell command in "check" that exits 0 once it is fixed and non-zero now, if one can be written; otherwise null. #{if round > 1, do: "This is round #{round}: report blockers and warnings only, no notes.", else: ""} Return an empty findings list if nothing qualifies.

      ## Rules
      #{rules}

      ## Ticket #{t.id}: #{t.title}
      owns: #{Enum.join(t.owned, ", ")}
      #{String.trim(t.description)}
      acceptance:
      #{Enum.map_join(t.checks, "\n", &"- `#{&1}`")}

      ## Diff (#{s.epic_branch}...#{w.branch})
      #{String.slice(diff, 0, 120_000)}
      """

      case Model.one_shot("review:#{t.id}:round#{round}", get_in(s.cfg, ["review", "model"]), prompt, Model.review_schema(), timeout: 600_000) do
        nil -> nil
        res ->
          findings = (res["findings"] || []) |> Enum.filter(&(round == 1 or &1["severity"] != "note"))
          blockers = Enum.filter(findings, &(&1["severity"] == "blocker"))
          warnings = Enum.filter(findings, &(&1["severity"] == "warning"))
          Log.info(w.agent_name, "per-ticket review round #{round}: #{length(blockers)} blockers, #{length(warnings)} warnings")
          Enum.each(warnings, fn f -> Br.comment(t.id, "review round #{round}: [warning] #{f["path"]}#{if f["line"], do: ":#{f["line"]}", else: ""} — #{f["summary"]} (rule: #{f["rule"]})", s.actor) end)
          %{blockers: blockers, warnings: warnings, findings: findings}
      end
    end
  end

  # ---------------------------------------------------------------- completion + integrated review + landing
  defp check_completion(s) do
    kids = Br.descendants(s.epic)
    open = Enum.reject(kids, &(&1["status"] == "closed"))

    cond do
      open != [] ->
        waiting = Enum.filter(open, &(&1["status"] == "blocked"))
        if length(waiting) == length(open), do: Log.info("loop", "all remaining tickets wait on a human: #{Enum.map_join(waiting, ", ", & &1["id"])}")
        {false, s}

      get_in(s.cfg, ["integratedReview", "enabled"]) && s.review_rounds < (get_in(s.cfg, ["integratedReview", "maxRounds"]) || 0) ->
        {filed, s} = review_epic(s)
        if filed, do: {false, s}, else: land(s)

      true ->
        land(s)
    end
  end

  defp review_epic(s) do
    round = s.review_rounds + 1
    Timing.timed(s.epic, nil, "integrated-review", fn -> review_epic(s, round) end, &%{round: round, filed: elem(&1, 0)})
  end

  defp review_epic(s, round) do
    doing("integrated review round #{round}")
    State.put_review_rounds(s.integration.path, round)
    s = %{s | review_rounds: round}
    diff = Git.diff(s.cfg["repo"], s.cfg["baseBranch"], s.epic_branch)

    if String.trim(diff) == "" do
      Log.info("review", "empty diff; nothing to review")
      {false, s}
    else
      rules = case get_in(s.cfg, ["integratedReview", "rulesFile"]), do: (nil -> ""; f -> File.read!(f))
      kids = Br.descendants(s.epic) |> Enum.map(&(Br.show(&1["id"]) |> Tickets.parse()))
      ticket_block = Enum.map_join(kids, "\n\n", fn t -> "### #{t.id}: #{t.title}\nowns: #{Enum.join(t.owned, ", ")}\n#{String.trim(t.description)}\nacceptance:\n#{Enum.map_join(t.checks, "\n", &"- `#{&1}`")}" end)

      prompt = """
      You are reviewing the integrated branch of an epic with fresh eyes. You get the diff, the rules, and each ticket's stated requirements; you did not write this and you do not see the authors' reasoning. Flag only correctness and requirement gaps against the rules. Something a ticket explicitly asks for, or that its acceptance checks require, is never a finding. Every finding cites one rule from the list and the path it applies to (line when visible in the diff). For a blocker, give a shell command in "check" that exits 0 once it is fixed and non-zero now, if one can be written; otherwise null. #{if round > 1, do: "This is round #{round}: report blockers and warnings only, no notes.", else: ""} Return an empty findings list if nothing qualifies.

      ## Rules
      #{rules}

      ## Tickets
      #{ticket_block}

      ## Diff (#{s.cfg["baseBranch"]}...#{s.epic_branch})
      #{String.slice(diff, 0, 120_000)}
      """

      case Model.one_shot("review:round#{round}", get_in(s.cfg, ["integratedReview", "model"]), prompt, Model.review_schema(), timeout: 600_000) do
        nil ->
          Log.info("review", "round #{round}: reviewer returned no verdict")
          {false, s}

        res ->
          findings = (res["findings"] || []) |> Enum.filter(&(round == 1 or &1["severity"] != "note"))
          blockers = Enum.filter(findings, &(&1["severity"] == "blocker"))
          Log.info("review", "round #{round}: #{length(findings)} findings, #{length(blockers)} blockers")
          filed = Enum.reduce(Enum.reject(findings, &(&1["severity"] == "note")), false, fn f, filed -> route_finding(f, kids, round, s) or filed end)
          Enum.each(Enum.filter(findings, &(&1["severity"] == "note")), fn f -> Br.comment(s.epic, "review note: #{f["path"]} — #{f["summary"]}", s.actor) end)
          {filed, s}
      end
    end
  end

  # A blocker never reopens a closed ticket. It becomes a bug, child of the ticket whose owned paths
  # it falls in (or of the epic), inheriting owned paths and acceptance checks. br ready --epic is
  # recursive, so the same loop picks it up. Warnings are comments.
  defp route_finding(f, kids, round, s) do
    owner = Enum.find(kids, &Tickets.path_owned?(f["path"], &1.owned))
    text = "[#{f["severity"]}] #{f["path"]}#{if f["line"], do: ":#{f["line"]}", else: ""} — #{f["summary"]} (rule: #{f["rule"]})"

    if f["severity"] != "blocker" do
      Br.comment(if(owner, do: owner.id, else: s.epic), "review round #{round}: #{text}", s.actor)
      Log.info("review", "#{if owner, do: owner.id, else: "epic"} warning recorded: #{String.slice(text, 0, 160)}")
      false
    else
      dir = case Path.dirname(f["path"]), do: ("." -> f["path"]; d -> d <> "/")
      owned = if owner, do: owner.owned, else: [dir]
      checks = (if owner, do: owner.checks, else: []) ++ if(f["check"], do: [f["check"]], else: [])

      id =
        Br.create(%{
          title: "Review: #{String.slice(f["summary"], 0, 80)}", type: "bug", parent: if(owner, do: owner.id, else: s.epic),
          deps: if(owner, do: "discovered-from:#{owner.id}", else: nil), labels: "review-finding", actor: s.actor,
          description: "#{text}\n\nFiled by the integrated-branch review, round #{round}#{if owner, do: ", against #{owner.id}. Owned paths and acceptance checks are inherited from it", else: ". No ticket owns this path; a human must confirm the owned path and acceptance checks"}. Fix it in a fresh worktree branched from the integration branch; the original work is already merged there."
        })

      Br.set_fields(id, "owned_paths:\n#{Enum.map_join(owned, "\n", &"- #{&1}")}\nmode: parallel", Enum.map_join(checks, "\n", &"- [ ] `#{&1}`"), s.actor)
      Log.info("review", "filed #{id} under #{if owner, do: owner.id, else: s.epic}: #{String.slice(text, 0, 160)}")
      true
    end
  end

  defp land(s), do: Timing.timed(s.epic, nil, "land", fn -> do_land(s) end)

  defp do_land(s) do
    doing("land")
    stat = Git.diff_stat(s.cfg["repo"], s.cfg["baseBranch"], s.epic_branch)
    Log.info("land", "epic #{s.epic} complete on #{s.epic_branch} after #{s.review_rounds} review round(s)\n#{stat}")

    if get_in(s.cfg, ["land", "openPullRequest"]) do
      r = EpicLoop.Sh.sh(~s(gh pr create --base #{s.cfg["baseBranch"]} --head #{s.epic_branch} --title "#{s.epic_issue["title"]}" --body "Epic #{s.epic}, built by epic-loop."), cwd: s.cfg["repo"])
      Log.info("land", "gh pr create -> exit #{r.code}: #{String.trim(r.out <> r.err)}")
    else
      Log.info("land", "land.openPullRequest is off. To open one: gh pr create --base #{s.cfg["baseBranch"]} --head #{s.epic_branch}")
    end

    State.attention(s.integration.path, "epic landed", "#{s.epic_branch} is ready.\n#{stat}")
    {true, s}
  end
end
