defmodule EpicLoop.Snapshot do
  @moduledoc """
  Everything the dashboard shows about one epic, as plain maps. Two halves, joined by `view/3`:

  - `collect/2` reads what any process can: the epic's tickets in br, herdr's worktrees and agents, the
    git state of every worktree cut from the epic, and the loop's files. It costs a few dozen short
    commands, so the dashboard caches it.
  - `live/0` runs inside the run: what its processes wrote to `EpicLoop.Board`, and their OTP process
    info. `EpicLoop.BoardFile` writes it to `board.json` every second, and the dashboard reads it back
    with `read_board/1`.

  `view/3` derives what the page shows: where the run stands, each ticket's state, which worker, agent
  and worktree belong together (a lane), what does not line up, and what needs the person.
  """
  alias EpicLoop.{Artifact, Board, Br, Git, Herdr, Integration, Sh, State, Tickets, Timing, Times, Usage, Worker}

  # Reads never take git's optional locks, so a page refreshing every few seconds cannot make a worker's
  # commit fail on index.lock.
  @git_env [{"GIT_OPTIONAL_LOCKS", "0"}]
  @log_bytes 96_000
  @log_entries 400

  # ---------------------------------------------------------------- outside the VM
  def collect(epic, cfg) do
    t0 = System.monotonic_time(:millisecond)
    repo = cfg["repo"]
    epic_branch = Integration.branch(cfg, epic)

    {epic_issue, e1} = attempt("br show #{epic}", nil, fn -> Br.show(epic) end)
    {issues, e2} = attempt("br show (tickets)", [], fn -> if epic_issue, do: descend(child_ids(epic_issue), MapSet.new([epic]), []), else: [] end)
    {ready, e3} = attempt("br ready", [], fn -> Br.ready(epic) |> Enum.map(& &1["id"]) end)
    marker = Git.marker(repo, epic_branch)
    ids = MapSet.new(issues, & &1["id"])

    worktrees =
      Herdr.worktree_list(repo)
      |> classify(epic_branch, ids, &(marker != nil and File.dir?(&1) and Git.descends_from?(&1, marker)), &reported_ticket/1)
      |> Task.async_stream(&worktree_facts(&1, epic_branch, cfg), timeout: 60_000, on_timeout: :kill_task, max_concurrency: 8)
      |> Enum.flat_map(fn {:ok, w} -> [w]; _ -> [] end)

    agents = classify_agents(Herdr.agent_list(), epic, ids, Enum.map(worktrees, &{&1.path, &1.ticket}))
    int = Enum.find(worktrees, &(&1.role == "integration"))

    %{
      epic: epic_issue, epic_branch: epic_branch, marker: marker,
      issues: Enum.sort_by(issues, &natural(&1["id"])), ready: MapSet.new(ready),
      worktrees: worktrees, agents: agents, files: if(int, do: epic_files(int.path), else: %{}),
      collected_at: Board.now(), collect_ms: System.monotonic_time(:millisecond) - t0, errors: Enum.reject([e1, e2, e3], &is_nil/1)
    }
  end

  defp attempt(what, default, fun) do
    {fun.(), nil}
  rescue
    e -> {default, "#{what}: #{Exception.message(e)}"}
  end

  # Every descendant through parent-child links, one `br show` per level of the tree.
  defp descend([], _seen, acc), do: acc

  defp descend(ids, seen, acc) do
    ids = ids |> Enum.uniq() |> Enum.reject(&MapSet.member?(seen, &1))
    issues = Br.show_many(ids)
    descend(Enum.flat_map(issues, &child_ids/1), MapSet.union(seen, MapSet.new(ids)), acc ++ issues)
  end

  defp child_ids(issue), do: for(d <- issue["dependents"] || [], d["dependency_type"] == "parent-child", do: d["id"])

  @doc "A sort key that puts `x.2` before `x.10`."
  def natural(id), do: Regex.split(~r/(\d+)/, id || "", include_captures: true, trim: true) |> Enum.map(&(case Integer.parse(&1), do: ({n, ""} -> {0, n}; _ -> {1, &1})))

  @doc """
  The repository's worktrees that belong to the epic, and as what, the way the loop decides it:
  `integration` (on the epic branch), `ticket` (on `ticket/<id>` for one of the epic's tickets, or cut from
  the marker with a report file naming one), or `stray` (cut from the marker, matching no ticket; the loop
  flags these and never merges them). Every other worktree is left out. `descends?` and `reported` stand
  in for git and the report file, and run only for worktrees the branch name does not settle.
  """
  def classify(wts, epic_branch, ids, descends?, reported) do
    Enum.flat_map(wts, fn w ->
      b = w["branch"]
      id = if is_binary(b), do: String.replace_prefix(b, "ticket/", "")

      role =
        cond do
          not w["is_linked_worktree"] -> nil
          b == epic_branch -> {"integration", nil}
          id != b and MapSet.member?(ids, id) -> {"ticket", id}
          not descends?.(w["path"]) -> nil
          MapSet.member?(ids, r = reported.(w["path"])) -> {"ticket", r}
          true -> {"stray", nil}
        end

      case role do
        nil -> []
        {role, ticket} -> [%{path: w["path"], branch: b, workspace_id: w["open_workspace_id"], role: role, ticket: ticket}]
      end
    end)
  end

  defp reported_ticket(path), do: (read_json(Artifact.report(path)) || %{})["ticket"]

  defp worktree_facts(w, epic_branch, cfg) do
    base = if w.role == "integration", do: cfg["baseBranch"], else: epic_branch

    if File.dir?(w.path) do
      w |> Map.merge(git_facts(w.path, base)) |> Map.merge(if(w.role == "integration", do: %{}, else: ticket_files(w.path, cfg)))
    else
      Map.put(w, :missing, true)
    end
  end

  defp git(cwd, args), do: Sh.run("git", args, cwd: cwd, env: @git_env, timeout: 20_000)

  defp git_facts(path, base) do
    head =
      case git(path, ["log", "-1", "--format=%h%x1f%ct%x1f%s"]) do
        %{code: 0, out: out} ->
          case String.split(String.trim(out), <<31>>, parts: 3) do
            [sha, ct, subject] -> %{sha: sha, time: String.to_integer(ct) * 1000, subject: subject}
            _ -> nil
          end

        _ ->
          nil
      end

    ahead = case git(path, ["rev-list", "--count", "#{base}..HEAD"]), do: (%{code: 0, out: o} -> String.trim(o) |> String.to_integer(); _ -> nil)
    dirty = git(path, ["status", "--porcelain", "--untracked-files=no"]).out |> String.split("\n", trim: true) |> length()
    stat = git(path, ["diff", "--shortstat", "#{base}...HEAD"]).out |> String.trim()
    %{head: head, base: base, ahead: ahead, dirty: dirty, shortstat: stat}
  end

  # What the loop and the worker left in a ticket's worktree, and what its agents spent in tokens.
  defp ticket_files(wt, cfg) do
    archived = archived_reports(wt)

    %{
      report: read_json(Artifact.report(wt)),
      last_report: archived |> List.last() |> read_json(),
      reports: length(archived),
      answer: read_text(State.answer_file(wt)),
      counters: read_json(State.counters_file(wt)),
      brief_at: mtime(Artifact.brief(wt)),
      usage: usage(wt, cfg)
    }
  end

  defp usage(wt, cfg) do
    extra = with re when is_binary(re) <- get_in(cfg, ["timing", "checkCommands"]), {:ok, r} <- Regex.compile(re), do: r, else: (_ -> nil)
    Usage.ticket(wt, extra)
  rescue
    _ -> nil
  end

  # report.<attempt>.<ms>.json, oldest first.
  defp archived_reports(wt) do
    Path.wildcard(Path.join(Artifact.dir(wt), "report.*.json"))
    |> Enum.sort_by(fn f -> case Regex.run(~r/\.(\d+)\.json$/, f), do: ([_, ms] -> String.to_integer(ms); _ -> 0) end)
  end

  defp epic_files(int) do
    delivered = with t when is_binary(t) <- read_text(State.delivered_file(int)), {n, ""} <- Integer.parse(String.trim(t)), do: n, else: (_ -> nil)

    %{
      attention: attention_entries(read_text(State.attention_file(int)) || "", delivered),
      log: log_entries(tail(State.log_file(int), @log_bytes)) |> Enum.take(-@log_entries),
      holder: State.holder(int),
      stop_requested: File.exists?(State.stop_file(int)),
      review_rounds: State.review_rounds(int)
    }
  end

  @doc """
  The entries of `attention.md`, oldest first: the timestamp and title of each `## <timestamp> <title>`
  heading and the body under it. `delivered` is how many bytes the integration session has been given;
  an entry counts as delivered once all of it lies within them, and a count past the end of the file
  means the file was replaced, so nothing in it has been. With no count, delivery is unknown (nil).
  """
  def attention_entries(text, delivered) do
    starts = Regex.scan(~r/^## /m, text, return: :index) |> Enum.map(fn [{i, _}] -> i end)
    delivered = if is_integer(delivered) and delivered > byte_size(text), do: 0, else: delivered

    starts
    |> Enum.zip(Enum.map(Enum.drop(starts, 1), &(&1 - 1)) ++ [byte_size(text)])
    |> Enum.map(fn {from, to} ->
      [heading | rest] = binary_part(text, from + 3, to - from - 3) |> String.split("\n", parts: 2)
      {ts, title} = case String.split(heading, " ", parts: 2), do: ([ts, t] -> {ts, t}; [t] -> {nil, t})
      %{ts: ts, title: String.trim(title), body: String.trim(Enum.join(rest)), delivered: if(is_integer(delivered), do: to <= delivered)}
    end)
  end

  @doc "`loop.log` lines as `%{ts, scope, msg}`; a line without a timestamp continues the entry before it."
  def log_entries(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce([], fn line, acc ->
      case {Regex.run(~r/^(\d{4}-\d\d-\d\dT\S+) \[([^\]]*)\] (.*)$/, line), acc} do
        {[_, ts, scope, msg], _} -> [%{ts: ts, scope: scope, msg: msg} | acc]
        {nil, [e | rest]} -> [%{e | msg: e.msg <> "\n" <> line} | rest]
        {nil, []} -> acc
      end
    end)
    |> Enum.reverse()
  end

  # The last `bytes` of a file, from the first whole line.
  defp tail(path, bytes) do
    with {:ok, %{size: size}} <- File.stat(path), {:ok, io} <- File.open(path, [:read, :binary]) do
      from = max(size - bytes, 0)
      data = case :file.pread(io, from, size - from), do: ({:ok, d} -> d; _ -> "")
      File.close(io)
      if from > 0, do: data |> String.split("\n", parts: 2) |> List.last(), else: data
    else
      _ -> ""
    end
  end

  @doc """
  The herdr agents that belong to the epic: the integration session (`epic-<id>`), each ticket's worker
  (`w-<ticket>`), and any unnamed agent whose working directory is inside one of the epic's worktrees.
  `worktrees` is `{path, ticket}` pairs; an agent inside one carries its path as `worktree`.
  """
  def classify_agents(agents, epic, ids, worktrees) do
    session = Integration.session_name(epic)
    names = Map.new(ids, &{Worker.agent_name(&1), &1})

    Enum.flat_map(agents, fn a ->
      within = Enum.find(worktrees, fn {path, _} -> is_binary(a["cwd"]) and (a["cwd"] == path or String.starts_with?(a["cwd"], path <> "/")) end)

      role =
        cond do
          a["name"] == session -> {"integration", nil}
          Map.has_key?(names, a["name"]) -> {"worker", names[a["name"]]}
          within -> {"unnamed", elem(within, 1)}
          true -> nil
        end

      case role do
        nil -> []
        {role, ticket} -> [%{name: a["name"], role: role, ticket: ticket, worktree: within && elem(within, 0), pane_id: a["pane_id"], workspace_id: a["workspace_id"], status: a["agent_status"], focused: a["focused"], title: a["terminal_title_stripped"], cwd: a["cwd"]}]
      end
    end)
  end

  defp read_text(nil), do: nil
  defp read_text(path), do: case(File.read(path), do: ({:ok, t} -> t; _ -> nil))
  defp read_json(path), do: with(t when is_binary(t) <- read_text(path), do: Sh.decode(t))
  defp mtime(path), do: case(File.stat(path, time: :posix), do: ({:ok, st} -> st.mtime * 1000; _ -> nil))

  # ---------------------------------------------------------------- inside the run
  @doc """
  What the run's processes wrote to `EpicLoop.Board`, with their OTP process info and the run's
  supervision tree: the live half, which `EpicLoop.BoardFile` writes to `board.json` every second. It
  calls none of the loop's processes, so it answers at once even while the coordinator runs a check.
  """
  def live do
    board = Board.all()
    run = entry(board, :run)
    coordinator = entry(board, :coordinator)
    workers = for({{:worker, _}, w} <- board, do: w) |> Enum.sort_by(&natural(&1.ticket))
    # The coordinator runs a merging ticket's checks and review itself; those count for that ticket.
    roles = Map.new([{run && run.coordinator, {"coordinator", coordinator && coordinator[:merging]}} | Enum.map(workers, &{&1.pid, {"worker", &1.ticket}})])

    commands =
      board
      |> Enum.flat_map(fn
        {{:cmd, _}, c} -> case roles[c.owner], do: ({role, ticket} -> if(Process.alive?(c.owner), do: [c |> Map.delete(:owner) |> Map.merge(%{role: role, ticket: ticket})], else: []); nil -> [])
        _ -> []
      end)
      |> Enum.sort_by(& &1.started_at)

    %{run: run, coordinator: coordinator, workers: Enum.map(workers, &Map.put(&1, :proc, proc(&1.pid))), commands: commands, tree: tree(workers), vm: if(run, do: vm())}
  end

  defp entry(board, key), do: Enum.find_value(board, fn {k, v} -> if k == key, do: v end)

  defp proc(pid) do
    case is_pid(pid) && Process.info(pid, [:message_queue_len, :memory, :reductions, :current_function, :status]) do
      kw when is_list(kw) -> %{pid: pid, mailbox: kw[:message_queue_len], memory: kw[:memory], reductions: kw[:reductions], status: kw[:status], current: mfa(kw[:current_function])}
      _ -> nil
    end
  end

  defp mfa({m, f, a}), do: "#{inspect(m)}.#{f}/#{a}"
  defp mfa(_), do: nil

  # The run's supervision tree, as the supervisors report it. A supervisor answers even while its children
  # are busy; the call is bounded anyway.
  defp tree(workers) do
    case Process.whereis(EpicLoop.RunSup) do
      nil -> []
      sup -> [tree_node("EpicLoop.RunSup", sup, :supervisor, workers)]
    end
  end

  defp tree_node(name, pid, type, workers) do
    children =
      if type == :supervisor do
        # A supervisor lists its children newest first; the page shows them in start order.
        for {id, cpid, ctype, _} <- Enum.reverse(which_children(pid)), is_pid(cpid) do
          label = case Enum.find(workers, &(&1.pid == cpid)), do: (%{ticket: t} -> "worker #{t}"; nil -> if(is_atom(id) and id != :undefined, do: inspect(id), else: "worker"))
          tree_node(label, cpid, ctype, workers)
        end
      else
        []
      end

    %{name: name, type: type, proc: proc(pid), children: children}
  end

  defp which_children(sup) do
    GenServer.call(sup, :which_children, 2_000)
  catch
    :exit, _ -> []
  end

  defp vm do
    %{
      os_pid: System.pid(), uptime_ms: elem(:erlang.statistics(:wall_clock), 0), memory: :erlang.memory(:total),
      processes: :erlang.system_info(:process_count), otp: to_string(:erlang.system_info(:otp_release)), elixir: System.version()
    }
  end

  @doc "The run's `board.json` in the integration worktree, decoded (string keys), or nil."
  def read_board(nil), do: nil
  def read_board(int_wt), do: read_json(State.board_file(int_wt))

  # ---------------------------------------------------------------- the view
  @stale_ms 10_000

  @doc "The external half when nothing could be read, and why."
  def empty(errors), do: %{epic: nil, epic_branch: nil, marker: nil, issues: [], ready: MapSet.new(), worktrees: [], agents: [], files: %{}, collected_at: Board.now(), collect_ms: 0, errors: errors}

  @doc """
  The page's data: the external half `ext`, the run's `board` as read from `board.json` (or nil), and
  `ctx` (`epic`, `cfg`, `url`). The board counts as live only while the run that wrote it holds the lock;
  otherwise it is what that run left behind, and the page shows it as the last it knew.
  """
  def view(ext, board, ctx) do
    cfg = ctx.cfg
    files = ext.files
    attention = files[:attention] || []
    # The loop records the landing in attention.md; once its worktrees are gone, a closed epic says it.
    landed = ext.issues != [] and Enum.all?(ext.issues, &(&1["status"] == "closed")) and (Enum.any?(attention, &(&1.title == "epic landed")) or (ext.epic || %{})["status"] == "closed")
    state = run_state(files[:holder], board, files[:stop_requested] || false, landed, Board.now())
    live = if state in ["running", "stopping", "unresponsive"], do: board
    run_active = files[:holder] != nil
    merging = live && get_in(live, ["coordinator", "merging"])
    workers = Map.new((live && live["workers"]) || [], &{&1["ticket"], &1})
    wts = ext.worktrees |> Enum.filter(&(&1.role == "ticket")) |> Map.new(&{&1.ticket, &1})
    status_of = Map.new(ext.issues, &{&1["id"], &1["status"]})
    ids = MapSet.new(Map.keys(status_of))

    tickets =
      Enum.map(ext.issues, fn i ->
        t = Tickets.parse(i)
        deps = for d <- i["dependencies"] || [], d["dependency_type"] == "blocks", do: %{id: d["id"], status: status_of[d["id"]] || d["status"], in_epic: MapSet.member?(ids, d["id"])}
        wt = wts[t.id]
        problems = Tickets.validate(t)

        {key, label} =
          ticket_state(%{
            status: t.status, close_reason: i["close_reason"], open_deps: Enum.reject(deps, &(&1.status == "closed")), problems: problems,
            ready: MapSet.member?(ext.ready, t.id), worker: workers[t.id], merging: merging == t.id, answer: wt && wt[:answer], run: run_active
          })

        %{
          id: t.id, title: t.title, type: i["issue_type"], priority: i["priority"], status: t.status, state: key, label: label,
          mode: t.mode, model: t.model, owned: t.owned, checks: t.checks, problems: problems, ready: MapSet.member?(ext.ready, t.id),
          blocked_by: deps, blocks: for(d <- i["dependents"] || [], d["dependency_type"] == "blocks", do: d["id"]), parent: i["parent"],
          description: t.description, design: i["design"], acceptance: i["acceptance_criteria"], notes: t.notes, close_reason: i["close_reason"],
          comments: Enum.map(i["comments"] || [], &Map.take(&1, ["author", "text", "created_at"])), labels: i["labels"] || [],
          assignee: i["assignee"], updated_at: i["updated_at"], closed_at: i["closed_at"], worktree: wt && wt.path
        }
      end)

    int = Enum.find(ext.worktrees, &(&1.role == "integration"))
    session = Enum.find(ext.agents, &(&1.role == "integration"))
    lanes = lanes(tickets, ext, live, run_active)
    last = if live == nil and is_map(board), do: Map.merge(Map.take(board["coordinator"] || %{}, ["pass", "activity", "merging", "next_tick_at"]), %{"written_at" => board["written_at"]})
    needs = run_needs(state, board, files[:holder], ctx) ++ needs_you(tickets, ext, ctx, int, landed)

    %{
      now: Board.now(),
      epic: ext.epic && %{id: ext.epic["id"], title: ext.epic["title"], status: ext.epic["status"], description: ext.epic["description"], labels: ext.epic["labels"] || []},
      epic_id: ctx.epic, branch: ext.epic_branch, marker: ext.marker,
      config: %{
        path: cfg["configPath"], repo: cfg["repo"], base: cfg["baseBranch"], poll_ms: cfg["pollIntervalMs"], max_workers: get_in(cfg, ["dispatch", "maxParallelWorkers"]),
        silence_ms: get_in(cfg, ["worker", "silenceMs"]), turn_max_ms: get_in(cfg, ["worker", "turnMaxMs"]), max_attempts: get_in(cfg, ["worker", "maxAttempts"]),
        review_rounds: if(get_in(cfg, ["review", "enabled"]) != false, do: get_in(cfg, ["review", "maxRounds"]) || 2),
        integrated_review_rounds: if(get_in(cfg, ["integratedReview", "enabled"]), do: get_in(cfg, ["integratedReview", "maxRounds"]) || 0)
      },
      run: %{
        state: state, live: live != nil, pid: files[:holder] || (is_map(board) && board["os_pid"]) || nil,
        started_at: is_map(board) && get_in(board, ["run", "started_at"]) || nil, board_at: is_map(board) && board["written_at"] || nil,
        ended: is_map(board) && board["ended"] || nil, ended_at: is_map(board) && board["ended_at"] || nil,
        url: ctx.url, stop_requested: files[:stop_requested] || false, review_rounds: files[:review_rounds]
      },
      loop: live && live["coordinator"],
      last: last,
      counts: Enum.frequencies_by(tickets, & &1.state) |> Map.put("total", length(tickets)),
      tickets: tickets,
      lanes: lanes,
      integration: int && Map.merge(int, %{session: session}),
      stray_agents: stray_agents(ext.agents, lanes, Map.new(tickets, &{&1.id, &1.status}), live != nil, int && int.path),
      stray_worktrees: stray_worktrees(ext.worktrees),
      processes: live && %{vm: live["vm"], tree: live["tree"] || [], commands: live["commands"] || []},
      needs_you: needs,
      attention: attention_history(Enum.reverse(attention), open_keys(needs)),
      log: files[:log] || [],
      collected_at: ext.collected_at, collect_ms: ext.collect_ms, errors: ext.errors
    }
  end

  @doc "One epic's line on the dashboard's front page, from its view."
  def summary(v) do
    %{
      epic_id: v.epic_id, title: v.epic && v.epic.title, epic_status: v.epic && v.epic.status, repo: v.config.repo, config: v.config.path,
      run: v.run, loop: v.loop && Map.take(v.loop, ["pass", "next_tick_at", "activity", "activity_since", "merging", "merge_started_at"]), last: v.last,
      counts: v.counts, needs: Enum.count(v.needs_you, &(&1.kind != "landed")), in_flight: Enum.count(v.lanes, & &1.worker),
      max_workers: v.config.max_workers, integration: v.integration && v.integration.path, errors: v.errors
    }
  end

  @doc """
  A ticket's state on the page, `{key, label}`: br's status, refined by the ticket's worker while its run
  is live. The worker is as `board.json` has it (string keys). The key picks the color and the icon.
  """
  def ticket_state(%{status: "closed"} = t), do: if(String.contains?(t.close_reason || "", "fast-forwarded"), do: {"merged", "merged"}, else: {"closed", "closed"})
  def ticket_state(%{status: "blocked", answer: a}) when is_binary(a), do: {"answered", "answer queued"}
  def ticket_state(%{status: "blocked"}), do: {"needs_you", "needs you"}
  def ticket_state(%{worker: %{"phase" => "merging"}, merging: true}), do: {"merging", "merging"}
  def ticket_state(%{worker: %{"phase" => "merging"}}), do: {"queued", "in merge queue"}
  def ticket_state(%{worker: %{"phase" => "pending_merge"}}), do: {"queued", "merge deferred"}
  def ticket_state(%{worker: %{"phase" => "awaiting_human"}}), do: {"needs_you", "needs you"}
  def ticket_state(%{worker: %{"phase" => "starting"}}), do: {"working", "starting"}
  def ticket_state(%{worker: %{}}), do: {"working", "working"}
  def ticket_state(%{status: "in_progress", run: true}), do: {"orphan", "no worker yet"}
  def ticket_state(%{status: "in_progress"}), do: {"orphan", "in progress, no run"}
  def ticket_state(%{status: "open", open_deps: [_ | _]}), do: {"waiting", "waiting on deps"}
  def ticket_state(%{status: "open", problems: [_ | _]}), do: {"incomplete", "incomplete"}
  def ticket_state(%{status: "open", ready: true}), do: {"ready", "ready"}
  def ticket_state(%{status: s}), do: {"open", s}

  @doc """
  Where the epic's run stands, from the lock's holder (the pid of a live epic_loop process, or nil) and
  the board file the run rewrites every second:

  - `running`, or `stopping` once the kill switch is set: the holder's board is fresh;
  - `unresponsive`: the holder's board has not changed for #{div(@stale_ms, 1000)} seconds, so its VM may be stuck;
  - `starting`: the holder has written no board yet, or is an epic_loop that predates the board file;
  - `landed`: every ticket closed and the landing recorded;
  - `ended`: no holder, and the last board records how the run ended;
  - `died`: no holder, and the last board records no end;
  - `stopped`: no holder and no board: no run since the worktree was made.
  """
  def run_state(holder, board, stop?, landed?, now) do
    ours = holder != nil and is_map(board) and board["os_pid"] == holder

    cond do
      ours and board["ended"] == nil and now - (board["written_at"] || 0) > @stale_ms -> "unresponsive"
      ours and board["ended"] == nil -> if(stop?, do: "stopping", else: "running")
      holder != nil and not ours -> "starting"
      landed? -> "landed"
      is_map(board) and board["ended"] != nil -> "ended"
      is_map(board) -> "died"
      true -> "stopped"
    end
  end

  # One lane per ticket, in the tickets' order. Each joins the ticket and what it waits on, its worker,
  # its agent, its worktree and the commands its worker runs, and names what does not line up.
  defp lanes(tickets, ext, live, run_active) do
    workers = Map.new((live && live["workers"]) || [], &{&1["ticket"], &1})
    agents = ext.agents |> Enum.filter(&(&1.ticket && &1.role != "integration")) |> Enum.group_by(& &1.ticket)
    wts = ext.worktrees |> Enum.filter(&(&1.role == "ticket")) |> Map.new(&{&1.ticket, &1})
    cmds = Enum.group_by((live && live["commands"]) || [], & &1["ticket"])

    Enum.map(tickets, fn t ->
      w = workers[t.id]
      a = agents[t.id] || []
      agent = Enum.find(a, &(&1.role == "worker")) || List.first(a)
      wt = wts[t.id]
      %{ticket: t.id, title: t.title, status: t.status, state: t.state, label: t.label, blocked_by: t.blocked_by, worker: w, agent: agent, worktree: wt, commands: cmds[t.id] || [], issues: lane_issues(t, w, agent, wt, live != nil, run_active)}
    end)
  end

  @doc """
  The epic's agents that no ticket row and no integration section accounts for, each with `why`: an
  agent in the integration worktree besides its session, one in a stray worktree, a second agent in a
  ticket's worktree, a ticket's agent left open after the ticket closed, and, while the run is live, a
  ticket's agent with no worker process behind it. Without a live run, the agent of a ticket in progress
  or waiting is what the next run adopts, so it is not listed.
  """
  def stray_agents(agents, lanes, status_of, live, int_path) do
    shown = for(l <- lanes, l.agent, do: l.agent.pane_id) |> MapSet.new()
    driven = for(l <- lanes, l.worker, do: l.ticket) |> MapSet.new()

    Enum.flat_map(agents, fn a ->
      why =
        cond do
          a.role == "integration" -> nil
          a.ticket == nil and a.worktree == int_path -> "an agent in the integration worktree besides its session"
          a.ticket == nil -> "an agent in the stray worktree #{a.worktree}"
          not MapSet.member?(shown, a.pane_id) -> "a second agent in the worktree of #{a.ticket}"
          status_of[a.ticket] == "closed" -> "left open after #{a.ticket} closed"
          live and a.role == "worker" and not MapSet.member?(driven, a.ticket) -> "no worker process drives it"
          true -> nil
        end

      if why, do: [Map.put(a, :why, why)], else: []
    end)
  end

  @doc "The worktrees cut from the epic that match no ticket, each with `why`."
  def stray_worktrees(worktrees) do
    for w <- worktrees, w.role == "stray" do
      why =
        case w.branch do
          "ticket/" <> id -> "its branch names #{id}, which is not a ticket under the epic"
          nil -> "detached, and descends from the epic marker"
          b -> "#{b} descends from the epic marker but matches no ticket by branch name or report file"
        end

      Map.put(w, :why, why)
    end
  end

  @doc """
  What does not line up in a lane: the ticket, its worker (as `board.json` has it), its agent and its
  worktree. `live` says the run's board is current; `run` that a run holds the lock at all.
  """
  def lane_issues(t, w, agent, wt, live, run) do
    [
      if(w && w["phase"] == "running" && agent == nil, do: "herdr has no agent named #{w["agent_name"]}; the worker starts a new one after two polls"),
      if(w == nil && live && t.status == "in_progress", do: "no worker process; the next pass adopts it"),
      if(w == nil && !run && agent && t.status in ["in_progress", "blocked"], do: "agent open with no run; the next run adopts it"),
      if(agent && agent.status == "blocked", do: "the agent shows a dialog"),
      if(agent && agent.role == "unnamed", do: "an unnamed agent is working in this worktree"),
      if(t.status == "closed" && agent, do: "the agent is still open after the ticket closed"),
      if(w && w["wt"] && wt == nil, do: "herdr no longer lists the worktree #{w["wt"]}"),
      if(wt && wt[:missing], do: "the worktree folder is gone")
    ]
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  A run that died, or that holds the lock but stopped writing its board, needs the person: it drives
  nothing, and only a new run (or a look at the stuck one) moves the epic on. `at` is when its board was
  last written, as ISO 8601.
  """
  def run_needs(state, board, holder, ctx) do
    at = is_map(board) && is_integer(board["written_at"]) && (board["written_at"] |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601())
    c = (is_map(board) && board["coordinator"]) || %{}
    was = if c["merging"], do: " It was merging #{c["merging"]}.", else: if(c["pass"], do: " It was at pass #{c["pass"]}.", else: "")
    start = "epic_loop run --epic #{ctx.epic} --config #{ctx.cfg["configPath"]}"

    case state do
      "died" -> [%{kind: "run", heading: "The run died", at: at || nil, command: start, body: "Its last board records no end: the process crashed or was killed.#{was} A new run adopts the tickets it left in progress."}]
      "unresponsive" -> [%{kind: "run", heading: "The run is not responding", at: at || nil, body: "pid #{holder} holds the lock, but its board.json stopped changing, so its VM may be stuck.#{was} The log's last lines say what it did last; stop it with `kill #{holder}` and start a new run to go on."}]
      _ -> []
    end
  end

  # What only the person can move: questions and escalations, then whatever else stops the loop.
  defp needs_you(tickets, ext, ctx, int, landed) do
    wts = ext.worktrees |> Enum.filter(&(&1.role == "ticket")) |> Map.new(&{&1.ticket, &1})
    attention = ext.files[:attention] || []
    cmd = fn id -> ~s(epic_loop answer --epic #{ctx.epic} --config #{ctx.cfg["configPath"]} --ticket #{id} --text "<your answer>") end

    questions =
      for t <- tickets, t.state == "needs_you" do
        wt = wts[t.id] || %{}
        report = Enum.find([wt[:report], wt[:last_report]], &match?(%{"status" => "needs-human"}, &1))
        entry = attention |> Enum.filter(&(entry_key(&1.title) == {:ticket, t.id})) |> List.last()

        %{
          kind: "question", ticket: t.id, title: t.title, heading: (entry && entry.title) || "#{t.id} is blocked",
          question: report && report["question"], options: (report && report["options"]) || [], unblock: report && report["unblock"],
          body: (entry && entry.body) || t.notes, at: entry && entry.ts, command: cmd.(t.id), has_worktree: wt != %{}
        }
      end

    flags =
      [
        int && (int[:dirty] || 0) > 0 && %{kind: "dirty", heading: "The integration worktree has uncommitted changes", body: "#{int.path} has #{int.dirty} changed tracked file(s). No ticket merges until it is clean: commit or stash them in the integration session."},
        for(w <- ext.worktrees, w.role == "stray", do: %{kind: "stray", path: w.path, heading: "Stray worktree #{w.path}", body: "Branch #{w.branch || "(detached)"} descends from the epic marker but matches no ticket. Nothing from it merges."}),
        for(t <- tickets, t.state == "incomplete", do: %{kind: "incomplete", ticket: t.id, heading: "#{t.id} cannot be dispatched", body: Enum.join(t.problems, "; ") <> ". The loop skips it until the fields are set."}),
        for(a <- ext.agents, a.status == "blocked", do: %{kind: "dialog", ticket: a.ticket, heading: "#{a.name || a.pane_id} shows a dialog", body: "herdr reports the agent in pane #{a.pane_id} as blocked on a dialog."}),
        landed && %{kind: "landed", heading: "Epic landed on #{ext.epic_branch}", body: "Every ticket is closed and the branch is ready.", command: "gh pr create --base #{ctx.cfg["baseBranch"]} --head #{ext.epic_branch}"}
      ]
      |> List.flatten()
      |> Enum.filter(&is_map/1)

    questions ++ flags
  end

  # What each open item in Needs you would have been reported as in attention.md.
  defp open_keys(needs) do
    needs
    |> Enum.flat_map(fn
      %{kind: "question", ticket: t} -> [{:ticket, t}]
      %{kind: "incomplete", ticket: t} -> [{:incomplete, t}]
      %{kind: "stray", path: p} -> [{:stray, p}]
      %{kind: "dirty"} -> [:dirty]
      %{kind: "landed"} -> [:landed]
      _ -> []
    end)
    |> MapSet.new()
  end

  @doc """
  The entries of `attention.md`, newest first, each with a `status`: `open` while Needs you still shows
  what it reported, `resolved` once it does not, and nil for an entry of a kind Needs you never shows.
  Only the newest entry about a thing can be open; an earlier one about the same thing is resolved, and
  so is a ticket's question or escalation older than an answer to that ticket. An answer is never
  delivered to the session, so it carries no `delivered`.
  `open` holds the keys of what Needs you shows: `{:ticket, id}`, `{:incomplete, id}`, `{:stray, path}`,
  `:dirty`, `:landed`.
  """
  def attention_history(newest_first, open) do
    newest_first
    |> Enum.map_reduce(MapSet.new(), fn e, seen ->
      case entry_key(e.title) do
        nil -> {Map.put(e, :status, nil), seen}
        {:answer, t} -> {Map.merge(e, %{status: nil, delivered: nil}), MapSet.put(seen, {:ticket, t})}
        k -> {Map.put(e, :status, if(MapSet.member?(open, k) and not MapSet.member?(seen, k), do: "open", else: "resolved")), MapSet.put(seen, k)}
      end
    end)
    |> elem(0)
  end

  # The titles the loop writes: see the State.attention/3 callers in Coordinator and Worker, and State.answered/5.
  defp entry_key(title) do
    cond do
      m = Regex.run(~r/^(\S+) answered (by|from) /, title) -> {:answer, Enum.at(m, 1)}
      m = Regex.run(~r/^(\S+) (needs you|escalated)$/, title) -> {:ticket, Enum.at(m, 1)}
      m = Regex.run(~r/^(\S+) cannot be dispatched$/, title) -> {:incomplete, Enum.at(m, 1)}
      m = Regex.run(~r/^stray epic worktree (.+)$/, title) -> {:stray, Enum.at(m, 1)}
      title == "integration worktree has uncommitted changes" -> :dirty
      title == "epic landed" -> :landed
      true -> nil
    end
  end

  # ---------------------------------------------------------------- a ticket, on demand
  @doc "What the page's ticket panel adds to the snapshot: the brief, the commits, the diffstat, every report, the agent's screen and the ticket's timing record."
  def ticket_detail(ext, id) do
    wt = Enum.find(ext.worktrees, &(&1.role == "ticket" and &1.ticket == id))
    agent = Enum.find(ext.agents, &(&1.ticket == id and &1.role == "worker"))

    files =
      if wt && File.dir?(wt.path) do
        base = ext.epic_branch

        %{
          brief: read_text(Artifact.brief(wt.path)),
          commits:
            git(wt.path, ["log", "--format=%h%x1f%ct%x1f%s", "-n", "50", "#{base}..HEAD"]).out
            |> String.split("\n", trim: true)
            |> Enum.map(fn l -> case String.split(l, <<31>>, parts: 3), do: ([h, ct, s] -> %{sha: h, time: String.to_integer(ct) * 1000, subject: s}; _ -> %{sha: l}) end),
          diffstat: git(wt.path, ["diff", "--stat", "#{base}...HEAD"]).out,
          reports:
            ([Artifact.report(wt.path)] ++ Enum.reverse(archived_reports(wt.path)))
            |> Enum.flat_map(fn f -> case read_json(f), do: (nil -> []; r -> [%{file: Path.basename(f), unread: f == Artifact.report(wt.path), report: r}]) end)
        }
      else
        %{}
      end

    screen = if agent && agent.name, do: (case Herdr.agent_read(agent.name, 60), do: ({:ok, t} -> t; _ -> nil))
    times = with %{"id" => epic} <- ext.epic, [_ | _] = recs <- Timing.read(epic), do: Times.report(recs, id), else: (_ -> nil)
    Map.merge(%{id: id, worktree: wt && wt.path, agent: agent && agent.name, screen: screen, times: times}, files)
  end

  # ---------------------------------------------------------------- JSON
  @doc "The term with everything JSON cannot carry made into strings: pids, tuples, invalid UTF-8."
  def jsonable(%MapSet{} = m), do: m |> MapSet.to_list() |> jsonable()
  def jsonable(%{__struct__: _} = s), do: s |> Map.from_struct() |> jsonable()
  def jsonable(m) when is_map(m), do: Map.new(m, fn {k, v} -> {if(is_binary(k) or is_atom(k), do: k, else: inspect(k)), jsonable(v)} end)
  def jsonable(l) when is_list(l), do: Enum.map(l, &jsonable/1)
  def jsonable(b) when is_binary(b), do: String.replace_invalid(b)
  def jsonable(x) when is_pid(x) or is_reference(x) or is_port(x) or is_function(x) or is_tuple(x), do: inspect(x)
  def jsonable(x), do: x
end
