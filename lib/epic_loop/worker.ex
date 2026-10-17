defmodule EpicLoop.Worker do
  @moduledoc """
  One process per ticket in flight. Finds or creates the worktree, starts and briefs the herdr agent,
  polls it on its own timer, watches for stalls, reads the report file, and asks the coordinator to
  merge. Judgment calls (stall, in-plan question, retry class) are one-shot model calls.

  The worker records how long the ticket spends in each stage (see `EpicLoop.Timing`): it is always in
  one, and entering the next writes the one it leaves.
  """
  use GenServer, restart: :temporary
  alias EpicLoop.{Artifact, Board, Br, Brief, Coordinator, Git, Herdr, Log, Model, Session, Sh, State, Tickets, Timing, Worktrees}

  defstruct [
    :ticket, :mode, :cfg, :epic, :epic_issue, :epic_branch, :marker, :actor,
    :branch, :wt, :int_wt, :pane_id, :workspace_id, :agent_name, :model, :saved,
    attempt: 1, review_round: 0, started_at: 0, prompted_at: 0, last_text: "", last_change: 0,
    phase: :starting, stall_nudges: 0, no_report_nudges: 0, flaky_retry: false, missing: 0, stage: nil
  ]

  @trust_re ~r/trust|Yes, proceed|Enter to continue|press enter/i

  def start_link(args), do: GenServer.start_link(__MODULE__, args)
  def ticket(pid), do: safe_call(pid, :ticket)
  def worktree(pid), do: safe_call(pid, :worktree)
  def phase(pid), do: safe_call(pid, :phase)

  defp safe_call(pid, msg) do
    try do
      GenServer.call(pid, msg, 5_000)
    catch
      :exit, _ -> nil
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
  def agent_name(id), do: Session.name("w-", id)
  defp agent_live?(s), do: Enum.any?(Herdr.agent_list(), &(&1["name"] == s.agent_name))
  defp report_path(wt), do: Artifact.report(wt)
  defp wd(s, key), do: get_in(s.cfg, ["worker", key])

  @impl true
  def init(args) do
    t = args.ticket

    s = %__MODULE__{
      ticket: t, mode: args.mode, cfg: args.cfg, epic: args.epic, epic_issue: args.epic_issue, epic_branch: args.epic_branch,
      marker: args.marker, actor: args.actor, int_wt: args.integration, branch: Worktrees.branch(t.id), agent_name: agent_name(t.id),
      model: t.model || get_in(args.cfg, ["worker", "model"]), started_at: now(), last_change: now(),
      stage: {"setup", Timing.now(), %{title: t.title, adopted: args.mode == :adopt}}
    }

    send(self(), :setup)
    {:ok, s}
  end

  @impl true
  def handle_call(:ticket, _, s), do: {:reply, s.ticket, s}
  def handle_call(:worktree, _, s), do: {:reply, s.wt, s}
  def handle_call(:phase, _, s), do: {:reply, s.phase, s}

  # ---------------------------------------------------------------- setup
  @impl true
  def handle_info(:setup, s) do
    publish(s)

    case locate_or_create(s) do
      # A ticket waiting on a human keeps its question: it stays blocked, and a later pass tries again.
      {:error, reason} when s.ticket.status == "blocked" ->
        Log.info(s.agent_name, "cannot set up: #{reason}; ticket stays blocked")
        {:stop, :normal, s}

      {:error, reason} ->
        Log.info(s.agent_name, "cannot set up: #{reason}; ticket goes back to open")
        Br.set_status(s.ticket.id, "open", nil, s.actor)
        {:stop, :normal, s}

      {:ok, s} ->
        Artifact.warn_unless_ignored(s.wt, s.ticket.id)
        Enum.each(get_in(s.cfg, ["worker", "worktreeSetup"]) || [], fn cmd -> r = Sh.sh(cmd, cwd: s.wt, timeout: s.cfg["checkTimeoutMs"] || 600_000); Log.info(s.ticket.id, "worker.worktreeSetup: #{cmd} -> exit #{r.code}") end)
        s = if s.mode == :adopt, do: s |> restore_counters() |> adopt(), else: start_agent(s, nil)
        s = s |> persist() |> publish()
        schedule_poll(s)
        {:noreply, s}
    end
  end

  def handle_info(:poll, s) do
    result =
      try do
        case s.phase do
          :awaiting_human -> check_waiting(s)
          :pending_merge -> request_merge(s)
          _ -> poll_agent(s)
        end
      rescue
        e -> Log.info(s.agent_name, "poll error: #{Exception.message(e)}"); {:continue, s}
      end

    case result do
      {:stop, s} -> {:stop, :normal, s}
      {:continue, s} -> s = s |> persist() |> publish(); schedule_poll(s); {:noreply, s}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp schedule_poll(s), do: Process.send_after(self(), :poll, s.cfg["pollIntervalMs"])

  # The counters live in the ticket's worktree so a restart continues from them: an adopted ticket keeps
  # its attempts and review rounds. A ticket dispatched from open starts fresh and overwrites them.
  defp restore_counters(s) do
    case State.load_counters(s.wt) do
      c when c == %{} -> s
      c -> Log.info(s.agent_name, "continuing from saved counters #{inspect(c)}"); struct(s, c)
    end
  end

  defp persist(%{wt: nil} = s), do: s

  defp persist(s) do
    c = Map.take(s, State.counter_keys())
    if c == s.saved, do: s, else: (State.save_counters(s.wt, c); %{s | saved: c})
  end

  # The dashboard's view of this worker (see EpicLoop.Board), published after setup and every poll. The
  # coordinator deletes it when the worker exits.
  defp publish(s) do
    Board.put({:worker, s.ticket.id}, %{
      pid: self(), ticket: s.ticket.id, title: s.ticket.title, phase: s.phase, adopted: s.mode == :adopt, model: s.model,
      attempt: s.attempt, review_round: s.review_round, stall_nudges: s.stall_nudges, no_report_nudges: s.no_report_nudges, missing: s.missing, flaky_retry: s.flaky_retry,
      agent_name: s.agent_name, pane_id: s.pane_id, workspace_id: s.workspace_id, wt: s.wt, branch: s.branch,
      started_at: Board.wall(s.started_at), prompted_at: if(s.prompted_at != 0, do: Board.wall(s.prompted_at)), last_change: Board.wall(s.last_change),
      next_poll_at: Board.now() + s.cfg["pollIntervalMs"], queued_at: nil
    })

    s
  end

  defp locate_or_create(s) do
    case Worktrees.find_ticket(s.cfg["repo"], s.epic_branch, s.marker, s.ticket.id) do
      {w, how} ->
        case Herdr.find_worktree_pane(s.cfg["repo"], w["path"]) || Herdr.worktree_open(s.cfg["repo"], w["path"]) do
          {:ok, c} ->
            Log.info(s.ticket.id, "reusing worktree #{w["path"]} (found by #{how}) in #{c.pane_id}")
            {:ok, %{s | wt: w["path"], branch: w["branch"], pane_id: c.pane_id, workspace_id: c.workspace_id}}
          _ -> {:error, "worktree #{w["path"]} exists but herdr cannot open it"}
        end

      nil when s.mode == :adopt ->
        {:error, "in_progress but no worktree"}

      nil ->
        base = if Git.rev(s.cfg["repo"], "refs/heads/#{s.branch}"), do: s.branch, else: s.epic_branch
        case Herdr.worktree_create(s.cfg["repo"], s.branch, base, s.ticket.id) do
          {:ok, c} -> Log.info(s.ticket.id, "herdr created worktree at #{c.path}"); {:ok, %{s | wt: c.path, pane_id: c.pane_id, workspace_id: c.workspace_id}}
          {:error, e} -> {:error, "herdr worktree create: #{e}"}
        end
    end
  end

  # A restart keeps a live agent and its conversation. A ticket waiting on a human stays waiting and
  # starts nothing: the answer, or a report the person steered the agent to, moves it on, and
  # check_answer starts an agent if none is live by then.
  defp adopt(s) do
    live = Enum.find(Herdr.agent_list(), &(&1["name"] == s.agent_name))
    s = if live, do: %{s | pane_id: live["pane_id"]}, else: s

    cond do
      File.exists?(State.answer_file(s.wt)) or s.ticket.status == "blocked" ->
        Log.info(s.agent_name, "adopted while waiting on a human#{if live, do: "; agent live in #{live["pane_id"]}", else: ""}")
        enter(%{s | phase: :awaiting_human}, "human", %{from: "implement"})

      live ->
        Log.info(s.agent_name, "adopted live agent in #{live["pane_id"]}")
        enter(%{s | prompted_at: now(), phase: :running}, "implement", %{model: s.model})

      true ->
        start_agent(s, "Previous attempt was interrupted by an orchestrator restart. The worktree keeps its commits; continue from them.")
    end
  end

  # ---------------------------------------------------------------- agent lifecycle
  # The stage the ticket is in, and when it began (see EpicLoop.Timing). Entering one records the one it
  # leaves, with the attempt and review round it began in.
  defp enter(s, name, fields \\ %{}) do
    s = leave(s)
    %{s | stage: {name, Timing.now(), Map.merge(%{attempt: s.attempt, review_round: s.review_round}, fields)}}
  end

  defp leave(%{stage: {name, start, fields}} = s) do
    Timing.span(s.epic, s.ticket.id, name, start, fields)
    %{s | stage: nil}
  end

  defp leave(s), do: s

  defp write_brief(s, extra), do: (Artifact.ensure_dir(s.wt); File.write!(Artifact.brief(s.wt), Brief.build(%{ticket: s.ticket, epic: s.epic_issue, cfg: s.cfg, branch: s.branch, attempt: s.attempt, extra: extra})))

  # The ticket as br has it now, so owned paths, checks and notes changed while it runs reach the next
  # brief and the next verification. When br cannot answer, the copy in hand stays.
  defp refresh(s) do
    case (try do
            Br.show(s.ticket.id)
          rescue
            _ -> nil
          end) do
      %{} = issue -> %{s | ticket: Tickets.parse(issue)}
      _ -> s
    end
  end

  # Every start is a fresh agent. A leftover one under the same name (a run stopped without closing
  # it, an agent the person left open) would fail the start with agent_name_taken, so it is closed
  # first.
  defp start_agent(s, extra) do
    s = %{refresh(s) | stall_nudges: 0, no_report_nudges: 0, missing: 0}

    case Session.stop(s.agent_name) do
      :ok -> launch(s, extra)
      {:error, e} -> escalate(s, "could not start a fresh agent: the previous one did not exit (#{e}). Close Claude in pane #{s.pane_id}, then answer to start one.")
    end
  end

  defp launch(s, extra) do
    s = enter(s, "implement", %{model: s.model})
    write_brief(s, extra)
    Session.pre_trust(s.wt)
    args = ["--model", s.model | get_in(s.cfg, ["worker", "claudeArgs"]) || []]

    case Session.start(s.agent_name, s.pane_id, args, wd(s, "agentStartTimeoutMs")) do
      :ok ->
        Log.info(s.agent_name, "attempt #{s.attempt} started with #{s.model} in #{s.pane_id} (#{s.wt})")
        prompt(s, Brief.prompt_text())

      {:error, e} ->
        escalate(s, "worker failed to start: #{e}")
    end
  end

  defp prompt(s, text) do
    case Herdr.agent_prompt(s.agent_name, text) do
      {:ok, _} -> %{s | prompted_at: now(), last_change: now(), phase: :running}
      {:error, e} -> escalate(s, "prompt failed: #{e}")
    end
  end

  # Escape cancels the turn; the next prompt waits until the agent is idle so it is not typed into a
  # running tool.
  defp cancel_turn(s) do
    Herdr.agent_send_keys(s.agent_name, ["esc"])
    Herdr.agent_wait(s.agent_name, until: "idle", timeout: 30_000)
  end

  defp respawn(s, reason) do
    if s.attempt + 1 > wd(s, "maxAttempts") do
      escalate(s, "gave up after #{s.attempt} attempts: #{reason}")
    else
      s = %{s | attempt: s.attempt + 1, model: get_in(s.cfg, ["worker", "retryModel"])}
      Log.info(s.agent_name, "respawning (attempt #{s.attempt}, #{s.model}): #{reason}")
      start_agent(s, "Previous attempt ended: #{reason}. The worktree keeps its commits; continue from them.")
    end
  end

  # A merged ticket's agent is closed, so its name is free and nothing is left running in its pane.
  defp retire(s) do
    s = leave(s)
    with {:error, e} <- Session.stop(s.agent_name), do: Log.info(s.agent_name, "could not close the agent after the merge: #{e}")
    # The agents are closed, so their transcripts are complete.
    Timing.agents(s.epic, s.ticket.id, s.wt, get_in(s.cfg, ["timing", "checkCommands"]))
    if get_in(s.cfg, ["worker", "keepWorktreeAfterMerge"]) == false and s.workspace_id, do: Log.info(s.agent_name, "worktree removed: #{Herdr.worktree_remove(s.workspace_id)}")
    s
  end

  defp escalate(s, reason) do
    try do
      Br.set_status(s.ticket.id, "blocked", "epic-loop escalation: #{String.slice(reason, 0, 1500)}", s.actor)
    rescue
      e -> Log.info(s.agent_name, "could not mark blocked: #{Exception.message(e)}")
    end

    State.attention(s.int_wt, "#{s.ticket.id} escalated", "#{reason}\n\nWorktree: #{s.wt}\nPane: #{s.pane_id}\nResume with: epic_loop answer --epic #{s.epic} --config #{s.cfg["configPath"]} --ticket #{s.ticket.id} --text \"<instruction>\"")
    wait_human(s, "escalation")
  end

  # ---------------------------------------------------------------- polling
  @doc """
  What a worker waiting on a human does on a poll. An answer comes first. Failing that, a report the
  worker wrote since then, because the person steered it in its pane, is read once the agent has
  stopped (`gone` when herdr no longer has it). Otherwise it keeps waiting.
  """
  def waiting_plan(true, _report?, _status), do: :answer
  def waiting_plan(false, true, status) when status in ["idle", "done", "gone"], do: :report
  def waiting_plan(_answer?, _report?, _status), do: :wait

  defp check_waiting(s) do
    report? = File.exists?(report_path(s.wt))

    status =
      if report? do
        case Herdr.agent_get(s.agent_name) do
          {:ok, st} -> st
          {:error, "agent_not_found"} -> "gone"
          _ -> "unknown"
        end
      end

    case waiting_plan(File.exists?(State.answer_file(s.wt)), report?, status) do
      :answer ->
        {:continue, check_answer(s)}

      :report ->
        Log.info(s.agent_name, "report written while waiting on a human; reading it")
        Br.set_status(s.ticket.id, "in_progress", "epic-loop: the worker reported while the ticket waited on a human", s.actor)
        handle_report(%{s | phase: :running})

      :wait ->
        {:continue, s}
    end
  end

  # The answer goes to the live agent. When there is none (its start failed, or it exited while the
  # ticket waited), a prompt would fail with agent_not_found and escalate again, so a fresh agent
  # starts instead, with the answer in its brief.
  defp check_answer(s) do
    f = State.answer_file(s.wt)

    if File.exists?(f) do
      text = File.read!(f) |> String.trim()
      File.rm!(f)
      Br.set_status(s.ticket.id, "in_progress", "epic-loop: answered: #{text}", s.actor)

      if agent_live?(s) do
        Log.info(s.agent_name, "answer received; resuming")
        prompt(resume(s), continue_text(text))
      else
        Log.info(s.agent_name, "answer received; no live agent, starting one")
        start_agent(s, "Answer to what blocked this ticket: #{text}")
      end
    else
      s
    end
  end

  defp poll_agent(s) do
    got = Herdr.agent_get(s.agent_name)
    s = if match?({:ok, _}, got), do: %{s | missing: 0}, else: s

    case got do
      # Gone on two polls in a row: its Claude exited or its pane closed. One miss may be herdr
      # between detections, so it is only noted.
      {:error, "agent_not_found"} when s.missing >= 1 ->
        {:continue, respawn(s, "the agent is gone: its Claude session exited or its pane closed")}

      {:error, "agent_not_found"} ->
        Log.info(s.agent_name, "agent not found; a new one starts if it is still gone on the next poll")
        {:continue, %{s | missing: 1}}

      {:error, e} ->
        Log.info(s.agent_name, "agent get failed: #{e}")
        {:continue, s}

      {:ok, "blocked"} ->
        text = case Herdr.agent_read(s.agent_name, 40), do: ({:ok, t} -> t; _ -> "")

        if Regex.match?(@trust_re, text) do
          Log.info(s.agent_name, "trust dialog on screen; selecting Yes")
          Herdr.agent_send_keys(s.agent_name, ["down", "enter"])
          {:continue, s}
        else
          {:continue, escalate(s, "worker is blocked on a dialog the loop does not answer:\n```\n#{String.slice(text, -1500, 1500)}\n```\nAnswer it in pane #{s.pane_id}, then run: epic_loop answer --epic #{s.epic} --config #{s.cfg["configPath"]} --ticket #{s.ticket.id} --text \"continue\"")}
        end

      {:ok, st} when st in ["idle", "done"] ->
        cond do
          now() - s.prompted_at < 20_000 -> {:continue, s}
          File.exists?(report_path(s.wt)) -> handle_report(s)
          s.no_report_nudges == 0 ->
            Log.info(s.agent_name, "stopped without a report; nudging once")
            {:continue, prompt(%{s | no_report_nudges: 1}, "You stopped without writing ./.agent_artifact/epic-loop/report.json. If the work is complete and committed, write it now with status \"done\". If not, finish per ./.agent_artifact/epic-loop/brief.md and then write it. Then stop.")}
          true -> handle_failure(s, "worker stopped twice without writing .agent_artifact/epic-loop/report.json")
        end

      {:ok, status} ->
        over = now() - s.prompted_at > wd(s, "turnMaxMs")

        case Herdr.agent_read(s.agent_name, 40) do
          {:ok, text} ->
            s = if text != s.last_text, do: %{s | last_text: text, last_change: now()}, else: s
            silent = now() - s.last_change > wd(s, "silenceMs")

            cond do
              over -> {:continue, handle_stall(s, status, "turn cap", text)}
              silent -> {:continue, handle_stall(s, status, "silence", text)}
              true -> {:continue, s}
            end

          # A failed read is no evidence of silence; only the turn cap still applies.
          {:error, e} ->
            Log.info(s.agent_name, "agent read failed: #{e}")
            if over, do: {:continue, handle_stall(s, status, "turn cap", "")}, else: {:continue, s}
        end
    end
  end

  @doc """
  What a stall trigger leads to. Nothing to read is no evidence, so the agent is left alone. A
  silent agent that herdr reports as working is running something quiet (a test suite, a build),
  so it is left alone until the turn cap. Everything else goes to the judge.
  """
  def stall_plan(_status, _trigger, text) when text in [nil, ""], do: :wait
  def stall_plan("working", "silence", _text), do: :wait
  def stall_plan(_status, _trigger, _text), do: :judge

  defp handle_stall(s, status, why, text) do
    case stall_plan(status, why, text) do
      :wait ->
        Log.info(s.agent_name, "watchdog: #{why} while herdr reports #{status}#{if text == "", do: " and the screen is unreadable", else: ""}; waiting")
        grace(s, why)

      :judge ->
        judge_stall(s, why, text)
    end
  end

  # Restart the clock the trigger measures, so the same trigger does not fire again on the next poll.
  defp grace(s, "turn cap"), do: %{s | prompted_at: now(), last_change: now()}
  defp grace(s, _silence), do: %{s | last_change: now()}

  defp judge_stall(s, why, text) do
    verdict = Model.one_shot("stall:#{s.ticket.id}", get_in(s.cfg, ["worker", "judgmentModel"]), "You are a watchdog for an automated coding worker. Trigger: #{why}. Below are the last lines of its terminal. Decide whether it is still making progress (working) or stuck, looping, or waiting on input that will never come (stalled). A running command, a spinner or an elapsed-time counter means working. If no terminal lines appear below, answer working. Answer with the schema only.\n\n---\n#{String.slice(text, -6000, 6000)}", Model.stall_schema())

    cond do
      verdict && verdict["verdict"] == "working" ->
        Log.info(s.agent_name, "watchdog: still working (#{verdict["reason"]})")
        grace(s, why)

      s.stall_nudges == 0 ->
        Log.info(s.agent_name, "watchdog: stalled (#{(verdict || %{})["reason"] || "no verdict"}); nudging")
        cancel_turn(s)
        prompt(%{s | stall_nudges: 1}, "You appear to be stuck. Re-read ./.agent_artifact/epic-loop/brief.md and continue. If something the brief does not settle is blocking you, write ./.agent_artifact/epic-loop/report.json with status \"needs-human\" and one concrete question, then stop.")

      true ->
        respawn(s, "stalled twice (#{why})")
    end
  end

  # ---------------------------------------------------------------- report handling
  defp handle_report(s) do
    rp = report_path(s.wt)
    parsed = case File.read(rp), do: ({:ok, j} -> Sh.decode(j); _ -> nil)
    File.rename(rp, Artifact.archived_report(s.wt, s.attempt))

    case parsed do
      nil -> handle_failure(s, "unreadable .agent_artifact/epic-loop/report.json")
      report ->
        Log.info(s.agent_name, "report: #{report["status"]}", %{commits: report["commits"], checks: length(report["checks"] || [])})
        case report["status"] do
          "needs-human" -> {:continue, handle_question(s, report)}
          "failed" -> handle_failure(s, "worker reported failure: #{report["notes"] || ""}")
          _ -> request_merge(s)
        end
    end
  end

  defp continue_text(answer), do: "Answer: #{answer}\nContinue per ./.agent_artifact/epic-loop/brief.md. Write ./.agent_artifact/epic-loop/report.json as it specifies when done, then stop."

  defp handle_question(s, report) do
    q = "#{report["question"] || "(no question given)"}\nOptions: #{Enum.join(report["options"] || [], " | ")}\nWhat the answer decides: #{report["unblock"] || ""}"
    rules = case get_in(s.cfg, ["worker", "rulesFile"]), do: (nil -> ""; f -> File.read!(f))

    a = Model.one_shot("plan-answer:#{s.ticket.id}", get_in(s.cfg, ["worker", "judgmentModel"]), "A worker on ticket #{s.ticket.id} asked a question. Decide whether the epic, the ticket and the rules below already settle it unambiguously. If they do, answer in one or two sentences the worker can act on. If they do not, set answered=false; never guess.\n\n## Epic\n#{s.epic_issue["title"]}\n#{s.epic_issue["description"] || ""}\n\n## Ticket\n#{s.ticket.title}\n#{s.ticket.description}\n\n## Rules\n#{rules}\n\n## Question\n#{q}", Model.plan_answer_schema())

    if a && a["answered"] do
      Log.info(s.agent_name, "question answered from the plan: #{a["answer"]}")
      Br.add_notes(s.ticket.id, "epic-loop answered from the plan: Q: #{report["question"]} A: #{a["answer"]}", s.actor)
      State.answered(s.int_wt, s.ticket.id, :plan, a["answer"], question: report["question"], why: a["reason"])
      prompt(s, continue_text(a["answer"]))
    else
      Br.set_status(s.ticket.id, "blocked", "needs-human: #{report["question"]}", s.actor)
      State.attention(s.int_wt, "#{s.ticket.id} needs you", "#{q}\n\nWorker notes: #{report["notes"] || ""}\n\nReply with:\n  epic_loop answer --epic #{s.epic} --config #{s.cfg["configPath"]} --ticket #{s.ticket.id} --text \"<your answer>\"")
      wait_human(s, "question")
    end
  end

  # Waiting on a person, and back: an answer to a live agent returns to the stage the ticket was in.
  defp wait_human(%{stage: {"human", _, _}} = s, _why), do: %{s | phase: :awaiting_human}
  defp wait_human(s, why), do: enter(%{s | phase: :awaiting_human}, "human", %{why: why, from: current_stage(s)})

  defp resume(%{stage: {"human", _, fields}} = s), do: enter(s, fields[:from] || "implement")
  defp resume(s), do: s

  defp current_stage(%{stage: {name, _, _}}) when name not in ["setup", "merge"], do: name
  defp current_stage(_s), do: "implement"

  defp handle_failure(s, detail) do
    Log.info(s.agent_name, "failure on attempt #{s.attempt}: #{detail |> String.split("\n") |> hd()}")
    Br.add_notes(s.ticket.id, "epic-loop attempt #{s.attempt} failed: #{String.slice(detail, 0, 1500)}", s.actor)

    cond do
      s.flaky_retry ->
        {:continue, escalate(s, "verification failed after a flaky retry:\n#{String.slice(detail, 0, 3000)}")}

      s.attempt == 1 ->
        {:continue, prompt(enter(%{s | attempt: 2}, "fix", %{after: "failure"}), "Verification failed:\n#{String.slice(detail, 0, 3000)}\n\nFix it inside your owned paths, rerun the acceptance checks, commit, and write ./.agent_artifact/epic-loop/report.json again. Then stop.")}

      s.attempt == 2 ->
        k = Model.one_shot("retry:#{s.ticket.id}", get_in(s.cfg, ["worker", "judgmentModel"]), "A worker's output failed verification twice. Classify the latest failure: flaky (nondeterministic; rerunning the checks would likely pass), environment (missing tool, network, permissions; not the worker's fault), or defect (the work is wrong or incomplete).\n\n#{String.slice(detail, 0, 6000)}", Model.retry_schema())

        case k && k["kind"] do
          "flaky" -> Log.info(s.agent_name, "classified flaky; re-verifying"); request_merge(%{s | attempt: 3, flaky_retry: true})
          "environment" -> {:continue, escalate(s, "environment problem: #{k["reason"]}\n#{String.slice(detail, 0, 2000)}")}
          _ -> {:continue, respawn(s, "defect after two attempts: #{(k || %{})["reason"] || (detail |> String.split("\n") |> hd())}")}
        end

      true ->
        {:continue, escalate(s, "still failing after #{s.attempt} attempts:\n#{String.slice(detail, 0, 3000)}")}
    end
  end

  # ---------------------------------------------------------------- merge (serialized in the coordinator)
  defp request_merge(s) do
    s = enter(refresh(s), "merge")
    # Blocks until the coordinator has decided, behind any merge ahead of it.
    Board.put({:worker, s.ticket.id}, %{phase: :merging, queued_at: Board.now(), next_poll_at: nil})

    case Coordinator.merge(s) do
      {:merged, upd} -> {:stop, retire(struct(s, upd))}
      {:handback, why, text, upd} -> {:continue, prompt(enter(struct(s, upd), "fix", %{after: why}), text)}
      {:verify_failed, detail} -> handle_failure(s, detail)
      {:escalate, reason} -> {:continue, escalate(s, reason)}
      {:retry_later, upd} -> {:continue, %{struct(s, upd) | phase: :pending_merge}}
    end
  end
end
