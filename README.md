# epic_loop

A program, not an agent. It drives one beads epic through herdr worktrees in two steps, with a person
in between:

    init:  epic/<id> + marker  ->  integration worktree  ->  interactive session in it
           (set the worktree up by hand, plan the tickets, then start the loop from that session)
    run:   br ready --epic  ->  claim  ->  worktree  ->  brief  ->  wait  ->  verify  ->  review  ->  fast-forward  ->  close

with a watchdog, a serial merge queue, a per-ticket review gate before every fast-forward, one
integrated-branch review round, and three one-shot judgment calls (stall classification, in-plan
question, retry classification). Reviews are also one-shot calls, with the diff and the rules only.
State lives in `br`, git and the worktrees; if the process dies, a new one re-adopts the tickets it left in progress or waiting on a human.

The design it implements is `docs/herdr-epic-loop.html` in this repository.

## Processes

- `EpicLoop.Integration`: the epic branch with its marker, the integration worktree and the interactive
  session in it. `init` creates them; `run` adopts them and refuses to start without them.
- `EpicLoop.Coordinator`: one per epic. Dispatch, the serial merge queue (a `GenServer.call`, so one
  merge is in flight by construction), the stray-worktree scan, the integrated review, landing, and
  delivering `attention.md` to the person (`EpicLoop.Attention`, see Reaching the person).
- `EpicLoop.Session`: starting a Claude session in a herdr pane (folder trust, pane readiness, the
  trust dialog), shared by the workers and the integration session.
- `EpicLoop.Worker`: one per ticket in flight, under a `DynamicSupervisor`. Finds or creates its
  worktree, starts and briefs the herdr agent, polls on its own timer, reads the report file, and
  calls the coordinator to merge. A crashed worker is re-adopted from `br` on the next pass. Before
  each agent start and each merge it reads the ticket from `br` again, so owned paths, checks and notes
  changed on a running ticket apply from then on.
- Everything external goes through `EpicLoop.Sh`: a port under `sh -c 'exec "$@"'` with a hard
  timeout that kills the tool's own pid, and stderr captured to a file.
- `EpicLoop.Board`: an ETS table the coordinator, each worker and every external command write their
  current state to as they go (the pass and the countdown to the next one, each worker's phase and
  watchdog clocks, each command in flight with its OS pid). Nothing reads it by calling a process,
  since a worker in the merge queue or a coordinator running a check would not answer.
- `EpicLoop.BoardFile`: writes the board, with the run's supervision tree and process info, to
  `board.json` every second for the dashboard (see Dashboard). A temporary child of the run's
  supervisor, so nothing that happens to it stops the loop.

## Install

It needs Claude Code, [herdr](https://herdr.dev) (the terminal multiplexer the agents run in),
[beads_rust](https://github.com/Dicklesworthstone/beads_rust) (`br`, where the epic and its tickets
live), `jq`, `git`, and Elixir 1.18+ (Homebrew: `brew install elixir jq`).

    git clone https://github.com/chaoqu/epic_loop.git ~/epic_loop
    cd ~/epic_loop && mix escript.build
    ln -sf ~/epic_loop/epic_loop ~/.local/bin/epic_loop      # or any directory on PATH
    ln -s ~/epic_loop/skills/epic-loop ~/epic_loop/skills/epic-plan ~/.claude/skills/

The two skills drive it from a Claude session: `epic-plan` writes an epic's tickets, and `epic-loop`
starts the loop and relays what it asks. Copy `config/example/` to `config/<your-repo>/`, point `repo`
at the repository, and map its paths to test suites in `checks.sh` (see Config and Monorepos).

## Build and run

Needs Elixir 1.18+ (Homebrew: `brew install elixir`). No dependencies; JSON is the standard library's.

    mix escript.build                     # produces ./epic_loop
    ./epic_loop init   --epic <id> --config config/<repo>/config.json   # branch, integration worktree, session in it
    ./epic_loop check  --epic <id> --config config/<repo>/config.json   # every ticket has owned_paths + checks
    ./epic_loop run    --epic <id> --config config/<repo>/config.json   # until the epic lands; needs init
    ./epic_loop status --epic <id> --config config/<repo>/config.json
    ./epic_loop answer --epic <id> --config config/<repo>/config.json --ticket <id> --text "<answer>" [--by person|session] [--why "<reason>"]
    ./epic_loop stop   --epic <id> --config config/<repo>/config.json   # kill switch
    ./epic_loop dashboard [--port <n>]    # one web page for every registered epic, at http://127.0.0.1:4040/
    ./epic_loop forget --epic <id>        # take an epic off the dashboard
    ./epic_loop times  --epic <id> [--ticket <id>]   # how long each stage took (see Timings)

Agent names: the integration session is `epic-<id>` and each worker `w-<ticket id>`, sanitized to
herdr's `[a-z][a-z0-9_-]{0,31}`. An id too long for that keeps its tail, which tells the tickets of
one epic apart, prefixed with a six-character hash of the whole id, for example
`w-1bc6ab-arithmetic-chain-qbcc-3`.

Run it from a herdr pane (`HERDR_ENV=1`). The log and the escalations are `loop.log` and `attention.md`
in the integration worktree's `.agent_artifact/epic-loop/` (see Files). Relative paths in the config
(`rulesFile`, `review.rulesFile`) resolve against the config file's directory.

## Dashboard

`epic_loop dashboard` serves one read-only web page for every epic, at `http://127.0.0.1:4040/` (`--port`;
a taken port falls back to a free one). Start it once and leave it running; a second start prints where
the first one is. The front page lists the epics: where each run stands, the countdown or what it is
doing, tickets merged, and how many things need you. `/e/<epic>` is one epic, refreshed every two
seconds:

- in the header, a small counter: when the coordinator's next pass runs, or the merge or pass in
  progress; a pass runs `pollIntervalMs` after the previous one ends, and none runs while a merge does;
- `loop.log` first, a few lines by default, with a button that shows more, a filter and a scope;
- what needs the person: a run that died or stopped responding, with the command to start another;
  each blocked ticket with its question, options and the `epic_loop answer` command to copy; a dirty
  integration worktree, stray worktrees, incomplete tickets, agents on a dialog;
- the integration branch: its head, commits ahead of the base branch, uncommitted files, its session, and
  how far `attention.md` has reached the session;
- the epic's tickets as a dependency graph, and a table of every ticket in br's order: what it waits on,
  its worker process (phase, attempt, review round, next poll), its herdr agent (name, pane, status,
  terminal title, and its context against the 1M window with the peak and the tokens so far), its worktree (branch, head, commits ahead, uncommitted files, report) and the command
  it is running, with the watchdog's silence and turn clocks against `silenceMs` and `turnMaxMs`, and a
  line for whatever does not line up. A ticket's panel (`#ticket=<id>` in the URL) adds its brief,
  commits, diffstat, every report, its log lines, its agent's screen, its tokens with what filled the
  context (the model's own output, prompts, the six tools and the six files whose results added the
  most) and its timing record (see Timings);
- the run's supervision tree with each process's mailbox and memory, and every external command in
  flight with its OS pid and age;
- stray and orphaned agents and worktrees, each with why: what no ticket row and no integration section
  accounts for, such as an agent left open after its ticket closed or a worktree cut from the epic that
  matches no ticket;
- the attention history, collapsed: every `attention.md` entry, newest first, whether it is still open
  in Needs you or resolved, and whether the integration session has been given it.

A run never talks to the dashboard, so a loop runs the same with or without one, and a dashboard
started at any time sees every run:

- Every command that names an epic and a config (`init`, `check`, `run`, `status`, `answer`, `stop`)
  registers the epic: a small file in `$XDG_STATE_HOME/epic_loop/epics/` (else
  `~/.local/state/epic_loop/epics/`) holding the epic id, its config and its integration worktree.
  `epic_loop forget` removes one. The dashboard records its own URL there too (`dashboard.json`), so
  `run` logs the epic's page and `status` prints it.
- The dashboard reads br, herdr, git and the loop's files for each epic.
- The run's live state (the countdown, the merge in progress, the workers, the commands in flight, the
  supervision tree) is `board.json` in the integration worktree, which the run rewrites every second.
  Together with the lock's holder it says where the run stands: `running` (or `stopping`), `not
  responding` when the holder's board has not changed for ten seconds, `starting` before its first board
  or for a run started by an epic_loop that predates the board file, `ended` when the last board records
  how the run ended, `died` when the holder is gone and its board records no end, `landed`, or no run.
  A run that ended or died keeps its last board, and the page shows where it was.

Tokens and context come from the Claude transcripts of each ticket's worktree (see Timings for where
they are), every session of the ticket together, with the context of the latest. A request's context,
less the previous request's, is what was added between them: first the previous request's own output,
then the tool results and prompts that arrived, split between them by size, and for reads (Read, and
`cat`, `head`, `tail`, `nl`, `sed -n` in Bash) between the files read. The dashboard reads each
transcript once, continuing where its last refresh stopped.

It only reads: answering and stopping stay with `epic_loop answer` and `epic_loop stop`. It listens on
127.0.0.1 only and answers only requests whose Host names that address. It collects from br, herdr and
git only while a page is open, at most every four seconds per epic, and its git reads take no optional
locks, so they never collide with a worker's commit.

## Worktrees

herdr creates one worktree workspace per ticket at its default location (no `--path`). The
integration branch starts with an empty marker commit, so "belongs to this epic" is a git fact: a
worktree whose HEAD descends from the marker. Which ticket it is comes from the `ticket/<id>` branch
name, or failing that from the ticket named in its `.agent_artifact/epic-loop/report.json`. Location is never consulted.
A worktree that descends from the marker but matches no ticket is flagged in `attention.md` and never
merged. The integration branch has a worktree of its own, created by `init` together with an
interactive session in it; that is where the epic is set up by hand, planned, and started from, and
`run` refuses to start without it. Merges are fast-forwards inside it, so the integrated code is
always checked out somewhere the app can run. It is never rebased while the epic runs, only
fast-forwarded, or rolled back by the loop after a failed integration check. Because a person works in
it too, the loop defers every merge while it has uncommitted tracked changes, and says so in
`attention.md` once.

## Files

Everything the loop writes about a run lives in the `.agent_artifact/epic-loop/` folder of a worktree,
which the repository ignores, so removing an epic's worktrees removes it; only the timing record is
kept elsewhere (see Timings). The folder is
untracked, so the merge gate, fast-forwards and rollbacks leave it alone; only `git clean -x` in the
integration worktree would erase it.

The integration worktree holds the epic's files:

| File | Contents |
|---|---|
| `loop.log` | every command's log lines; `init` writes to the terminal only until it has created the worktree |
| `attention.md` | escalations, questions and every answer to them, newest last |
| `attention.delivered` | how many bytes of `attention.md` the integration session has been given |
| `run.lock` | the OS pid of the active run. `run` refuses to start while that process is alive and takes over a lock whose process is gone |
| `stop` | the kill switch. `stop` writes it only while a run holds the lock; the run deletes it when it stops, and a new run deletes one left behind |
| `review-rounds` | integrated review rounds used so far |
| `board.json` | the run's live state for the dashboard, rewritten every second; the last write records how the run ended |

Each ticket worktree holds that ticket's files:

| File | Contents |
|---|---|
| `brief.md` | the worker's brief, rewritten at every agent start |
| `report.json`, `report.<attempt>.<ms>.json` | the worker's report, archived under a timestamped name once read |
| `answer` | an answer waiting for the worker; `epic_loop answer` finds the worktree the way the worker does |
| `counters.json` | the worker's attempt, review round and nudge counts. An adopted ticket continues from them; a ticket dispatched from `open` starts fresh and overwrites them |

Outside the worktrees, beads holds ticket status and history, and git config holds the epic branch's
marker commit in the branch's own section, which deleting the branch removes. Cleaning up a landed
epic is removing its worktrees and deleting its branches; its timing record stays.

## Timings

The loop records how long every stage took, one JSON object per line, in
`$XDG_STATE_HOME/epic_loop/timings/<epic>.jsonl` (else `~/.local/state/epic_loop/timings/`), next to
the dashboard's registry. It is kept outside the worktrees so the record of an epic outlives its
cleanup. `epic_loop times --epic <id>` prints the epic: its runs, every ticket stage summed, where the
agents' time went, and one row per ticket; `--ticket <id>` prints that ticket's stages in order, with
each check's and review's time, and each agent session's tools.

- A ticket's stages, written by its worker as it leaves each: `setup` (the worktree), `implement`
  (one per agent start, with its attempt and model), `fix` (after a failure, review blockers or a rebase
  conflict went back to the agent), `human` (waiting on an answer, with the stage it
  interrupted, to which a live agent returns), and `merge`, from asking to merge until the coordinator
  decides. Every moment of a ticket in flight is in exactly one of them; a run stopped mid-stage loses
  that stage's line, and the next run starts a new one.
- Within `merge`, the coordinator's steps: `queue` (waiting for the merges ahead), `rebase`, `verify`
  (each check's time and exit code), `review` (round, blockers, model) and `merge-checks` (each
  `checksAfterMerge` command).
- The epic's own: `integrated-review`, `land`, and `run`, one per run of the loop, with how it ended.
- `agent`: when a ticket merges, its worker reads the Claude Code transcript of every session in the
  ticket's worktree (`~/.claude/projects/<worktree path with every other character than a letter or
  digit made ->/`, or under `$CLAUDE_CONFIG_DIR`) and writes where each session's time went. Every gap
  between two transcript entries is charged to what was pending: the model's next block (thinking, or
  writing a tool call, which for Write and Edit is mostly the file's contents), a tool call in flight,
  a background command the agent waits on, or idle, waiting on the loop or a person. The parts add up
  to the session's length. Bash is split by its programs: `Bash:check` (builds, tests, linters, and
  `timing.checkCommands`), `Bash:wait` (polling loops), `Bash:write` (`sed -i`, heredocs into files,
  scripts that write), `Bash:read`, `Bash:git` and `Bash:other`. `times` groups the tools into reading,
  writing, checks and other. Each session's line also holds its tokens (input, cache reads and writes,
  output), its context peak, and what filled its context, with the twenty tools and files that filled
  the most, worked out as on the dashboard (see Dashboard); `times` prints them per session and summed
  over the epic. Claude Code deletes old transcripts (`cleanupPeriodDays`, 30 days by
  default), which is why the breakdown is written at the merge rather than computed later. A ticket that
  never merges gets no `agent` lines.

## Reaching the person

Every question the plan does not settle, every escalation, and the landing go into `attention.md`. On
its next pass the coordinator gives each new entry to the integration session, found by its agent
name `epic-<id>`, as a prompt carrying the entries and the `epic_loop answer` command for this epic and
config.

A ticket's question or escalation is the session's to settle first. When it has a recommended answer,
it sends that answer itself with `epic_loop answer --by session --why "<reason>"` and tells the person
what it answered. When it has none, because the choice belongs to the person (product behaviour no
spec describes, scope, cost, anything irreversible or touching production) or only the person can act
(a dialog in a worker's pane), it shows the entry as written and waits, and passes the person's reply
on with `--by person`.

Every answer goes into `attention.md` as `<ticket> answered by the integration session`, `answered by
the person` or, for a question the plan settles, `answered from the plan`, with the answer and why.
The dashboard's attention history shows it and marks the question it answers resolved. An answer is
a record: it raises no notification and never goes to the session.

A herdr notification with the request sound, which shows whatever pane the person is in, reaches the
person:

- for any other entry, at once;
- for a question, once the session leaves it to the person: the session ended the turn it was given
  the question in, or stopped on a dialog, and no answer to it has been recorded since. A question
  with no session to go to, or that the session could not be given for ten minutes, is notified then.

The prompt waits until herdr reports the session idle. While the session's pane has focus, the person
may be typing in it, so the prompt also waits until the screen has not changed for a whole pass. A
draft left untouched in a focused session for a pass is still submitted together with the prompt.
Entries the session cannot take yet (it is busy, closed, or renamed) stay pending, and one log line
says why. `attention.delivered` records how far the session has been given the file, so a restarted
run neither repeats nor drops an entry; a run that finds no `attention.delivered` starts at the end
of the file. A question still waiting on the session's turn when a run ends gets no notification from
the next run; Needs you on the dashboard still shows it.

## Config

Each repository has a folder `config/<name>/`: `config.json`, the worker and review rules, and any
scripts its checks call. `config/example/` is one to copy: a config, generic worker and review rules, and a
path-aware check script. Everything in the folder is about that repository, and any of it may move into
the repository later; the loop itself reads only `config.json` and whatever it points at.

The file is organized in the order the loop runs: base settings, then one block per phase. Relative
rules-file paths resolve against the config file's directory, so the rules sit next to it.

**Base**

| Key | Meaning |
|---|---|
| `repo`, `baseBranch` | the repository, and the branch epics fork from |
| `commitPrefix` | required start of every worker commit message |
| `beadsActor` | the `--actor` on every `br` write |
| `pollIntervalMs` | cadence of the coordinator pass and of each worker's poll |
| `checkTimeoutMs` | timeout for every check command, in any phase, and for every `worktreeSetup` command |

**`integration`**: what `init` builds once per epic: `<branchPrefix><epic-id>` from the base branch with its empty marker commit, its worktree, and the interactive session in it

| Key | Meaning |
|---|---|
| `branchPrefix` | prefix of the integration branch name, `epic/` by default |
| `worktreeSetup` | commands run once in the integration worktree when `init` creates it; keep them cheap and safe, heavy setup is the session's job |
| `model`, `claudeArgs` | the integration session's model (optional) and extra `claude` arguments |

**`dispatch`**: picking ready tickets and starting workers

| Key | Meaning |
|---|---|
| `maxParallelWorkers` | tickets in flight at once |

**`worker`**: the agent that does a ticket, in a worktree of its own

| Key | Meaning |
|---|---|
| `model`, `retryModel` | the worker's model, and the model a respawned worker gets |
| `judgmentModel` | the one-shot calls made about a worker: stall, in-plan question, retry class |
| `claudeArgs` | extra arguments to the worker's `claude` |
| `rulesFile` | rules text prepended to the brief |
| `worktreeSetup` | commands run once in a new ticket worktree, before the agent starts |
| `silenceMs`, `turnMaxMs` | pane silence, or one turn, long enough to trigger the watchdog; silence alone never interrupts an agent herdr reports as working |
| `maxAttempts` | respawns per ticket before escalating |
| `agentStartTimeoutMs` | how long to wait for a new pane and agent to be ready |
| `keepWorktreeAfterMerge` | whether a merged ticket's worktree workspace stays open |

**`verify`**: the loop reruns the checks in the ticket worktree after the worker stops

| Key | Meaning |
|---|---|
| `beforeChecks` | run before the checks (start the app) |
| `repoChecks` | checks every ticket must pass, appended to the ticket's own (the unit tests) |
| `afterChecks` | run after the checks, pass or fail (stop the app) |
| `protectedPathsRegex` | paths a ticket may never change (existing tests) |

**`review`**: the fresh-context review of one ticket's diff, before its fast-forward

| Key | Meaning |
|---|---|
| `enabled`, `model`, `maxRounds`, `rulesFile` | blockers go back to the worker up to `maxRounds` times, then escalate |

**`merge`**: the fast-forward into the integration worktree

| Key | Meaning |
|---|---|
| `checksAfterMerge` | run in the integration worktree after each fast-forward; failure rolls it back |
| `afterRollback` | run in the integration worktree after such a rollback (restart what runs on it) |

**`integratedReview`**: one review of the whole epic branch, once every ticket is closed

| Key | Meaning |
|---|---|
| `enabled`, `model`, `maxRounds`, `rulesFile` | blockers become bug children; a round that files nothing ends it |

**`land`**

| Key | Meaning |
|---|---|
| `openPullRequest` | run `gh pr create` when the epic lands |

**`timing`**: the timing record (see Timings)

| Key | Meaning |
|---|---|
| `checkCommands` | a regex for the repository's own check commands, so an agent's runs of them count as `Bash:check`; matched against each command of a Bash line from its program on. The usual build and test tools count without it |

## Monorepos

One config per repository, not per project: the unit the loop works in is a worktree and an integration
branch, and both are repository-wide. A monorepo with several toolchains puts the project boundary in the
tickets and in a path-aware check; `config/example/` is a starting point, with a `checks.sh` that maps
changed paths to the suites they touch.

- A ticket owns paths inside one project and carries that project's suite in its acceptance checks. Work
  that must land in two projects is two tickets with a `blocks` dependency, producer first; if the change
  cannot be split, one `serial` ticket owns both paths and lists both suites.
- `verify.repoChecks` and `merge.checksAfterMerge` name one script. It diffs the branch against its base,
  maps the changed paths to projects the way the CI workflows' `paths:` filters do, and runs only the
  touched suites. In a ticket worktree the base is the `epic/*` branch, so a documentation ticket does not
  build the whole repository; in the integration worktree the base is the base branch, so after every
  fast-forward the integrated code is checked in every project the epic has touched so far.
- Both `worktreeSetup` lists can stay empty when the check installs what it needs (`npm install`, a venv,
  a Docker image). A dev server the person runs in the integration worktree is theirs: the check never
  stops or restarts it, even when a build after a merge rewrites files under it.

## Ticket contract

Each ticket under the epic carries, in `br`:

- `design`:
  ```
  owned_paths:
  - path/one/
  mode: parallel | serial
  model: sonnet | opus        (optional)
  ```
- `acceptance_criteria`: checklist lines whose backticked text is a shell command run from the
  worktree root. Every command must exit 0.
- Only `blocks` dependencies gate dispatch (`br ready` semantics). Parent-child is not ordering.

The `epic-plan` skill (`skills/epic-plan/` in this repository) writes tickets to this contract and
sizes them: at most eight hand-written files a ticket. Past tickets of five files or fewer never took
their agents past 300k tokens of context; three in four of those over twenty files did.

Tickets can be added under the epic while the loop runs; every pass reads `br ready --epic` again. A
ready ticket without owned paths or backticked acceptance commands is skipped, not blocked, because
`br create` cannot set those fields and the loop often sees a new ticket between its create and its
update. It dispatches on the first pass that finds it complete; one still incomplete after five
minutes is reported in `attention.md` once. An incomplete ticket is still open, so the epic does not
land while one exists.

No beads policy file is needed. A review blocker never reopens a closed ticket; it is filed as a bug
under that ticket, and `br ready --epic` is recursive, so the loop sees it as ordinary open work.

## Worker contract

The worker gets `.agent_artifact/epic-loop/brief.md` in its worktree and nothing else. It commits on
its ticket branch, stays inside its owned paths, runs the acceptance checks, and writes
`.agent_artifact/epic-loop/report.json` (`done | failed | needs-human`) before it stops. The loop reads
the file, not the transcript. The loop merges commits only, so a ticket that changes no tracked file
(a manual step, or owned paths the repository ignores) ends with an empty commit, `git commit
--allow-empty`; the brief says so. `.agent_artifact/` is the repository's business to ignore in its
`.gitignore`; the loop never edits ignore files, and `init` and every new ticket worktree warn when the
folder is not ignored, because a worker that commits it fails verification.
herdr's `blocked` state only fires on a recognized dialog, so a question in prose is ignored.

While a ticket waits on a human, the integration session or the person answers with `epic_loop answer`
(see Reaching the person), or the person steers the worker in its pane until it writes a new report;
the loop reads that report once the agent stops, as if the ticket had never waited.

## Decisions by rule, not model

- done vs asking: the report's `status` field
- watchdog: a busy agent is read from its visible screen, since herdr scrolls back only while the agent is idle. Silence while herdr reports working, or a screen that cannot be read, is logged and waited out; the turn cap, or silence in any other state, goes to the stall call. A stalled verdict cancels the turn with Escape and nudges once the agent is idle; a second one respawns: Escape, wait for idle, `/exit`, wait until the name is free, then start the new agent
- agent lifecycle: every agent start is a fresh agent, and a leftover agent under the ticket's name is closed first (Escape, wait for idle, `/exit`, wait until the name is free), so a start never fails with `agent_name_taken`. An agent herdr cannot find on two polls in a row is respawned, which counts as an attempt. A merged ticket's agent is closed. `stop` ends the workers, then closes the agent of every ticket in flight; an agent whose ticket waits on a human stays open, idle, for the person and for the next run
- adoption: a new run adopts in-progress tickets, then blocked tickets that have a ticket worktree, up to `maxParallelWorkers`; the rest wait for a free slot. An adopted ticket keeps a live agent and its conversation; a waiting one stays waiting and starts nothing until it gets an answer or a report
- retries: re-prompt once, then classify (flaky -> re-verify, environment -> escalate, defect -> respawn with the retry model), then escalate
- merge order: one fast-forward at a time, after `git rebase epic/<id>`, green checks in the worktree, and a per-ticket review with zero blockers; conflicts and review blockers go back to the author in the same worktree, `review.maxRounds` times, then escalate
- merge gate: nothing merges while the integration worktree has uncommitted tracked changes; the worker keeps its report and asks again next pass
- review routing: a blocker becomes a bug ticket, child of the ticket whose owned paths it falls in (else of the epic), inheriting owned paths and acceptance checks plus the reviewer's fix check, linked with `discovered-from`; a warning is a comment; closed tickets stay closed
- exit: zero blockers, `integratedReview.maxRounds`, or a round that filed nothing
