---
name: epic-loop
description: Drive a beads epic with epic_loop in two steps. `init` creates the epic branch, its integration worktree and an interactive Claude session in that worktree; in that session the user sets the worktree up, plans the epic's tickets and starts the loop with `run`. The loop then gives each ticket its own herdr worktree and agent, verifies and reviews every change, and fast-forwards it into the integration branch. TRIGGER only when the user asks to init, run, start, resume, check, stop or answer an epic with the loop (for example "init epic proj-u33", "run epic proj-u33 with the loop", "/epic-loop run proj-u33"). Never start it on your own initiative: it creates worktrees, workspaces and agents, and it can file bug tickets.
disable-model-invocation: true
argument-hint: "init|check|run|status|stop <epic-id> [config-name]"
---

# epic-loop

`epic_loop` is a program, not an agent. Source and design: `~/epic_loop/README.md`
and `~/epic_loop/docs/herdr-epic-loop.html`. It works in two steps, and the person stays in the loop
between them:

1. `init` creates `epic/<id>` with its marker commit, a herdr worktree on it, and an interactive Claude
   session in that worktree. The person moves into that session, sets the worktree up by hand (dev
   server, production data, whatever the epic needs), and writes the epic's tickets there.
2. `run`, started from that session, reads the epic's ready tickets from `br`, claims each one, creates
   a herdr worktree and a worker agent for it, waits for the worker's report file, reruns the
   acceptance checks, reviews the diff with a fresh model call, fast-forwards the ticket branch into
   `epic/<id>` inside the integration worktree, and closes the ticket. When every ticket is closed it
   reviews the integrated branch once, files any blocker as a bug ticket, and lands.

You do not do the tickets. You run the commands, watch the loop, and relay what it needs.

## Before anything

1. Confirm you are inside herdr; the loop drives herdr panes and cannot run elsewhere:

   ```bash
   test "${HERDR_ENV:-}" = 1
   ```

   If that fails, say so and stop.

2. Confirm the command exists. The README's Install section builds it and links it into `~/.local/bin`:

   ```bash
   command -v epic_loop || (cd ~/epic_loop && mix escript.build)
   ```

3. Pick the repo config. Configs live in `~/epic_loop/config/<name>/config.json`, beside that
   repository's worker and review rules and check scripts. The
   user names one, or the repository the epic belongs to implies one. If no config exists for that
   repository, stop and tell the user which fields it needs (repo path, base branch, check script,
   setup commands, worker rules); `config/example/` is the template to copy. Do not invent a config.

4. Confirm the epic exists in `br` (`br show <id>`). The branch and worktree are named after its id,
   so it has to exist before `init`, even with nothing but a title.

## Step 1: `init`, from any session

```bash
epic_loop init --epic <id> --config ~/epic_loop/config/<name>/config.json
```

It prints the branch, the worktree path, the pane and the session name. Relay those, and tell the
user the rest happens in that session: switch to the pane (`herdr agent focus <session>`), set the
worktree up there with the repository's own skills and scripts, then plan. `init` is idempotent: run
again, it reuses the branch and worktree and reports the session already running.

Do not set the worktree up yourself from here, and do not plan the tickets from here; the integration
session has the checkout and is where the user wants to work.

## Step 2: in the integration session

**Plan.** Plan the tickets with the epic-plan skill: it sizes them (at most eight hand-written files
each), writes descriptions that settle what a worker would otherwise ask, and creates them in `br` once
the user approves the draft. What the loop needs from each child ticket, in `br`:

- `design` with `owned_paths:` (one path per `- ` line, inside one project of the repository),
  `mode: parallel | serial`, and optionally `model:`.
- `acceptance_criteria` whose backticked text is a shell command run from the worktree root; every
  command must exit 0. Only `blocks` dependencies order the work.

Validate before starting anything:

```bash
epic_loop check --epic <id> --config <config>
```

If a ticket fails, report the failing tickets and the missing fields and fix the tickets; that is the
planner's job and the planner is this session.

**Leave the worktree clean.** The loop fast-forwards and rolls back inside this worktree. Commit or
stash tracked changes before `run`; while the loop runs, the loop owns `epic/<id>`, so do not commit
on it and do not rebase or reset it. Untracked files are fine. A dirty worktree does not break
anything: the loop defers every merge and writes an `attention.md` entry until it is clean.

**Run.** Start the loop in a sibling pane so the user can watch it and it survives this session.
Follow the herdr skill's geometry rule (split a wide pane right, a tall pane down), keep the user's
focus:

```bash
P=$(herdr pane split --current --direction down --cwd ~/epic_loop --no-focus | jq -r .result.pane.pane_id)
herdr pane run "$P" "epic_loop run --epic <id> --config config/<name>/config.json"
```

Tell the user the pane id and where the log is: `.agent_artifact/epic-loop/loop.log` in the
integration worktree. `run` refuses to start when `init` has not created the integration worktree; it
never creates one itself. It also refuses while another run of the same epic is active, and names that
run's pid.

## While it runs

- Progress: `epic_loop status --epic <id> --config <config>` lists ticket states, whether a run is
  active, the epic's dashboard page, and the tail of `attention.md`, which holds every escalation and
  question. It lives next to the log in the integration worktree.
- Dashboard: `epic_loop dashboard` serves one read-only page for every epic at `http://127.0.0.1:4040/`;
  the user starts it once and leaves it running, and a second start prints where the first one is.
  Point the user at it when they ask what a loop is doing: each epic's page shows the countdown to the
  next pass, the merge in progress, every ticket's worker, agent and worktree side by side, and every
  question with its answer command. A run does not need it and never talks to it.
- Time: `epic_loop times --epic <id> [--ticket <id>]` prints how long each stage took (setup,
  implement, fixes, waiting on a person, and the merge's queue, rebase, verify, review and checks) and,
  for merged tickets, where the agents' time went (thinking, reading, writing, checks, each tool) and
  their tokens and what filled their context, by tool and by file. The record outlives the worktrees,
  so it answers after the epic lands too. The dashboard shows each running agent's context and tokens
  live, and the same breakdown in the ticket's panel.
- The loop sends every new `attention.md` entry to this session as a prompt, once the session is
  idle. Keep the name `init` gave this session (`epic-<id>`): the loop finds the session by it. A
  ticket's question or escalation is yours to settle first: when you have a recommended answer, send
  it yourself and tell the user in a few sentences what you answered and why. When you have none,
  because the choice is the user's (product behaviour no spec describes, scope, cost, anything
  irreversible or touching production) or only the user can act (a dialog in a worker's pane), show
  the entry verbatim with your analysis and wait. Show any other entry verbatim. Answer through the
  loop, never by prompting a worker pane yourself:

  ```bash
  epic_loop answer --epic <id> --config <config> --ticket <ticket-id> --by session --why "<why>" --text "<your answer>"
  epic_loop answer --epic <id> --config <config> --ticket <ticket-id> --by person --text "<the user's answer>"
  ```

  Every answer is recorded in `attention.md`, so the dashboard's attention history keeps who answered
  what. The loop notifies the user about a question only once you leave it to them: your turn ended
  with no answer recorded, or no session was there to take it.

- To steer a worker that asked a question, the user may talk to it in its own pane; once it writes a
  new report, the loop picks it up without an `epic_loop answer`. You still never prompt a worker pane
  yourself.
- Kill switch, only when the user asks. It reports when no run is active and then changes nothing.
  It closes the agent of every ticket in flight; agents waiting on the user stay open, and the next
  `run` adopts them:

  ```bash
  epic_loop stop --epic <id> --config <config>
  ```

- Do not open, prompt, or close the worker panes and worktree workspaces the loop creates. Do not
  change the status of the epic's tickets while the loop runs; it owns their status. Adding a new
  ticket under the epic is fine: the loop skips it until its `design` and `acceptance_criteria` are
  set, then dispatches it on the next pass.

## When it lands

The loop logs `epic <id> complete on epic/<id>` and the `gh pr create` command to open the pull
request, unless `land.openPullRequest` is set in the config, in which case it opened one. Report the
diffstat, the review outcome, and any bug children the review filed, then run `br sync --flush-only`.
