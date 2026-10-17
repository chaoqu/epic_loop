defmodule EpicLoop.CLI do
  @moduledoc "Entry point of the escript."
  alias EpicLoop.{Artifact, BoardFile, Br, Config, Dashboard, Epics, Git, Integration, Log, State, Tickets, Timing, Times, Worktrees}

  @usage """
  usage:
    epic_loop init   --epic <id> --config <file>            create epic/<id>, its integration worktree and the session in it
    epic_loop check  --epic <id> --config <file>            validate every ticket under the epic
    epic_loop run    --epic <id> --config <file> [--once]   run the loop until the epic lands (needs init)
    epic_loop status --epic <id> --config <file>
    epic_loop answer --epic <id> --config <file> --ticket <id> --text "<answer>" [--by person|session] [--why "<reason>"]
    epic_loop stop   --epic <id> --config <file>            kill switch: stop every worker, exit
    epic_loop dashboard [--port <n>]                        one web page for every registered epic (port 4040)
    epic_loop forget --epic <id>                            take an epic off the dashboard
    epic_loop times  --epic <id> [--ticket <id>]            how long each stage took, and where the agents' time went

  Every command that names an epic and a config registers the epic with the dashboard.
  """

  @commands ~w(init check run status answer stop)

  def main(argv) do
    {opts, args, _} = OptionParser.parse(argv, strict: [epic: :string, config: :string, once: :boolean, ticket: :string, text: :string, by: :string, why: :string, port: :integer])

    case {List.first(args), opts[:epic]} do
      {"dashboard", _} -> dashboard(opts[:port])
      {"forget", epic} when is_binary(epic) -> forget(epic)
      {"times", epic} when is_binary(epic) -> IO.write(Times.report(Timing.read(epic), opts[:ticket]))
      {cmd, _} -> command(cmd, opts)
    end
  end

  defp command(cmd, opts) do
    if cmd not in @commands or opts[:epic] == nil or opts[:config] == nil, do: usage_exit()

    cfg = Config.load(opts[:config])
    epic = opts[:epic]
    # The log lives in the integration worktree; until `init` has created it, lines go to the terminal only.
    int = Integration.find(cfg, Integration.branch(cfg, epic))
    if int, do: Log.open(State.log_file(int.path))
    Epics.register(epic, cfg, int && int.path)

    case cmd do
      "init" -> init(epic, cfg)
      "check" -> check(epic)
      "status" -> status(epic, int)
      "stop" -> stop(epic, cfg, int)
      "answer" -> answer(epic, cfg, int, opts)
      "run" -> run(epic, cfg, int, opts[:once] || false)
    end
  end

  defp usage_exit do
    IO.puts(:stderr, @usage)
    System.halt(2)
  end

  defp init(epic, cfg) do
    Br.show(epic) || abort("epic #{epic} not found in br; create the epic first, the branch and worktree are named after it")
    wt = Integration.ensure(cfg, epic)
    Epics.register(epic, cfg, wt.path)
    Log.open(State.log_file(wt.path))
    Log.info("init", "#{wt.branch} in #{wt.path}")

    case Integration.start_session(cfg, epic, wt) do
      {:ok, sess} ->
        IO.puts("""
        epic #{epic}
          branch    #{wt.branch}  (marker #{String.slice(wt.marker, 0, 8)})
          worktree  #{wt.path}#{if wt.created, do: "  (created; integration.worktreeSetup ran)", else: "  (existing)"}
          pane      #{sess.pane_id}
          session   #{sess.name}  #{if sess.started, do: "started", else: "already running (#{sess.status})"}
        #{if wt.ignored, do: "", else: "\nWARNING: #{EpicLoop.Artifact.root()}/ is not ignored by this repository. Add `#{EpicLoop.Artifact.root()}/` to its .gitignore and commit that on the base branch, or a worker may commit the loop's brief and report.\n"}
        In that session: set the worktree up (dev server, data), write the epic's tickets with owned paths
        and acceptance checks, commit anything tracked, then
          epic_loop check --epic #{epic} --config #{cfg["configPath"]}
          epic_loop run   --epic #{epic} --config #{cfg["configPath"]}
        """)

      {:error, e} ->
        abort("worktree ready at #{wt.path}, but #{e}")
    end
  end

  defp abort(msg) do
    IO.puts(:stderr, msg)
    System.halt(1)
  end

  defp run(epic, cfg, nil, _once),
    do: abort("no integration worktree for #{Integration.branch(cfg, epic)}; run `epic_loop init --epic #{epic} --config #{cfg["configPath"]}` first")

  defp run(epic, cfg, int, once) do
    case State.acquire_lock(int.path) do
      :ok -> :ok
      {:error, pid} -> abort("a run of #{epic} is already active in pid #{pid}; stop it with `epic_loop stop --epic #{epic} --config #{cfg["configPath"]}`")
    end

    # Holding the lock means no stop request can be meant for this run yet; one left by a run that died
    # before reading it would otherwise end this run on its first pass.
    if File.exists?(State.stop_file(int.path)), do: (File.rm(State.stop_file(int.path)); Log.info("loop", "removed a stop file left by an earlier run"))

    # The board comes first so every process can write to it; its file is written last, from what they
    # wrote. The file writer is a temporary child: whatever happens to it, the loop keeps running.
    children = [
      EpicLoop.Board,
      {DynamicSupervisor, name: EpicLoop.WorkerSup, strategy: :one_for_one},
      {EpicLoop.Coordinator, epic: epic, cfg: cfg, once: once, cli: self()},
      {BoardFile, integration: int.path}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: EpicLoop.RunSup)

    Log.info("dashboard", dashboard_url(epic) || "none running; `epic_loop dashboard` serves every epic, this run included")
    ref = Process.monitor(Process.whereis(EpicLoop.Coordinator))

    receive do
      {:epic_loop_done, reason} ->
        Log.info("loop", "exit: #{reason}")
        BoardFile.finish(int.path, to_string(reason))
        Supervisor.stop(sup)
        State.release_lock(int.path)

      {:DOWN, ^ref, :process, _, reason} ->
        Log.info("loop", "coordinator died: #{inspect(reason)}")
        BoardFile.finish(int.path, "coordinator died: #{String.slice(inspect(reason), 0, 300)}")
        State.release_lock(int.path)
        System.halt(1)
    end
  end

  # One dashboard serves every epic, so a second start points at the first instead of competing with it.
  defp dashboard(port) do
    case Epics.dashboard() do
      %{"url" => url, "pid" => pid} ->
        IO.puts("a dashboard is already running at #{url} (pid #{pid})")

      nil ->
        case Dashboard.start_link(port: port || Dashboard.default_port()) do
          {:ok, _} -> Process.sleep(:infinity)
          _ -> abort("the dashboard could not start; see the line above")
        end
    end
  end

  # This epic's page on the running dashboard, or nil when none runs.
  defp dashboard_url(epic), do: with(%{"url" => url} <- Epics.dashboard(), do: "#{url}e/#{URI.encode(epic)}", else: (_ -> nil))

  defp forget(epic) do
    case Epics.forget(epic) do
      :ok -> IO.puts("#{epic} is off the dashboard; any command naming it with --config puts it back")
      {:error, :enoent} -> IO.puts("#{epic} is not on the dashboard")
      {:error, e} -> abort("cannot forget #{epic}: #{inspect(e)}")
    end
  end

  # The stop file is written only while a run holds the lock, so a stop with nothing running leaves
  # nothing behind for the next run to trip over.
  defp stop(epic, cfg, nil), do: abort("no integration worktree for #{Integration.branch(cfg, epic)}; no run of #{epic} can be active")

  defp stop(epic, _cfg, int) do
    case State.holder(int.path) do
      nil ->
        IO.puts("no run of #{epic} is active; nothing to stop")

      pid ->
        File.write!(State.stop_file(int.path), Integer.to_string(System.os_time(:millisecond)))
        IO.puts("stop requested for the run in pid #{pid}")
    end
  end

  # An answer goes into the ticket's own worktree, where its worker reads it, and into attention.md,
  # where the attention history keeps who answered what. `--by session` is the integration session
  # answering on its own recommendation; the default is the person.
  @answer_by %{"person" => :person, "session" => :session}

  defp answer(epic, cfg, int, opts) do
    by = @answer_by[opts[:by] || "person"]
    if opts[:ticket] == nil or opts[:text] == nil or by == nil, do: usage_exit()
    epic_branch = Integration.branch(cfg, epic)

    case Worktrees.find_ticket(cfg["repo"], epic_branch, Git.marker(cfg["repo"], epic_branch), opts[:ticket]) do
      {w, _how} ->
        Artifact.ensure_dir(w["path"])
        File.write!(State.answer_file(w["path"]), opts[:text])
        if int, do: State.answered(int.path, opts[:ticket], by, opts[:text], why: opts[:why])
        IO.puts("answer queued for #{opts[:ticket]} in #{w["path"]}")

      nil ->
        abort("no worktree for #{opts[:ticket]}; an answer goes to a ticket the loop has started")
    end
  end

  defp check(epic) do
    kids = Br.descendants(epic)

    bad =
      Enum.count(kids, fn k ->
        t = Br.show(k["id"]) |> Tickets.parse()
        problems = Tickets.validate(t)
        deps = (t.raw["dependencies"] || []) |> Enum.filter(&(&1["dependency_type"] == "blocks")) |> Enum.map(& &1["id"])
        IO.puts("#{if problems == [], do: " ok ", else: "FAIL"} #{t.id} [#{t.status}] #{t.mode} owns #{Enum.join(t.owned, ",")} checks=#{length(t.checks)}#{if deps != [], do: " blocks-on " <> Enum.join(deps, ","), else: ""}#{if problems != [], do: "  <- " <> Enum.join(problems, "; "), else: ""}")
        problems != []
      end)

    IO.puts("#{length(kids)} tickets, #{bad} with problems")
    if bad > 0, do: System.halt(1)
  end

  defp status(epic, int) do
    Enum.each(Br.descendants(epic), fn k -> IO.puts("#{String.pad_trailing(k["status"], 12)} #{k["id"]}  #{k["title"]}") end)

    case int do
      nil ->
        IO.puts("\nno integration worktree; `epic_loop init` creates it")

      %{path: path} ->
        IO.puts("\nrun: " <> case(State.holder(path), do: (nil -> "none active"; pid -> "active in pid #{pid}")))
        f = State.attention_file(path)
        if File.exists?(f), do: IO.puts("\n--- #{f} ---\n" <> String.slice(File.read!(f), -3000, 3000))
    end

    IO.puts("\ndashboard: " <> (dashboard_url(epic) || "none running; `epic_loop dashboard` starts one"))
  end
end
