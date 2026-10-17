---
name: epic-plan
description: Plan the tickets of a beads epic that epic_loop will run. Find the files each piece of the work changes, split the work into tickets of at most eight hand-written files, give every ticket a self-contained description, owned paths, acceptance commands and its dependencies, and create them in br once the user approves the draft. TRIGGER when the user asks to plan, split, write, size or resize the tickets of an epic for the loop (for example "plan the tickets for proj-u33", "split this epic into tickets", "these tickets are too big"). Running the loop is the epic-loop skill's job.
argument-hint: "<epic-id> [config-name]"
---

# epic-plan

epic_loop gives every ticket a fresh agent in a worktree of its own. That agent's whole brief is the
epic's title and description, the ticket, and the repository's worker rules; it sees no other ticket and
cannot ask the planner anything. Two things decide how a ticket goes:

- **Its size.** The agent reads every file it changes and writes every line of the change, and all of
  it stays in its context. In past epics run by the loop, no ticket that changed five files or fewer took its
  agent past 300k tokens of context; three in four of those that changed more than twenty did.
- **What it leaves open.** A question the ticket does not settle stops its agent until a person
  answers. Waiting on answers took over half of the agents' wall-clock time in past epics.

Planning is where both are cheap to fix: you read the code once, here, and write down what every agent
would otherwise have to find out or ask.

This skill plans and writes tickets. It does not start the loop, and it creates or changes nothing in
br until the user approves the draft.

## Before anything

1. Read the epic: `br show <epic-id>`. Its description is the one text every agent reads, so it holds
   the goal and every decision that applies to more than one ticket. If it does not, the draft
   (step 4) includes a rewrite of it.
2. See what is already under it:

   ```bash
   epic_loop check --epic <epic-id> --config <config>
   ```

   lists every ticket with its status, owned paths, check count and dependencies.
3. Read the repository's loop config in `~/epic_loop/config/<name>/`:
   - `config.json`: `verify.repoChecks` (run for every ticket, so a ticket never lists them),
     and `dispatch.maxParallelWorkers`;
   - the worker rules file it names: what every agent follows, how each project's tests run, and every
     case in which a worker must report `needs-human`. Each of those cases is a question the plan
     settles before the loop runs;
   - the check script the repo checks call, to know what it runs for a given diff.
4. Read the design the user points to: a spec, an `html-plan` page, notes in the epic. Ask the user
   about anything in it that is still open before writing tickets on top of it.

## 1. Find the files

Read the code until you can name every file each part of the work creates, changes, deletes or moves,
and the existing code each part should follow. Write the list down; it is the input to everything
below. This is the reading every agent would otherwise do on its own.

## 2. Size the tickets

Count, for each ticket, every file it creates, changes, deletes or moves: source, tests, and
hand-written fixtures and mock data. Files a tool writes (generated code, rendered snapshots,
lockfiles) do not count.

- **Aim for five.** Up to eight when the files can only change together. Past eight, split the ticket.
- **Every ticket leaves the branch green.** It compiles and passes its own checks with only the tickets
  it depends on merged before it. A split that breaks the build in between is not a split.
- Ways to split:
  - one ticket per page, endpoint, job or command, rather than one per feature;
  - the shared piece first (a type, a helper, a migration, a fragment), then one ticket per consumer,
    each blocked by it;
  - a rename or move across many files, by directory or package, each step building on its own;
  - tests with the code they test, never in a ticket of their own.
- One project per ticket. Work that must land in two projects is two tickets, the producer first.

## 3. Write each ticket

**Title.** The outcome, in the imperative: "Render the users page from typed view models".

**Description.** Self-contained: the agent reads this and the epic, nothing else.

- What changes and why, in a few sentences.
- **Files**: each file to create, change, delete or move, with one line on what happens to it. This is
  the agent's map and the ticket's size in one list.
- **Follow**: the existing code to copy, as `path:line`, with why.
- **Decided**: names, URLs, shapes, states, behaviour at the edges: everything an agent would
  otherwise ask. A decision that applies to several tickets goes in the epic instead.
- **Not here**: what a neighbouring ticket does, so the agent does not start on it.

**Design.** The fields epic_loop reads, one per line:

```
owned_paths:
- path/to/file/one.kt
- path/to/new-directory/
mode: parallel
```

- `owned_paths` are the only paths the ticket may change; a diff outside them fails verification. List
  the files from the description, and a directory only where the ticket creates files inside it.
- Tickets that can run at the same time must not own overlapping paths; the loop holds back a ticket
  whose paths overlap one in flight.
- `mode: serial` for a ticket that touches what every ticket builds on (build files, shared config, a
  lockfile): it runs alone. Everything else is `parallel`.
- A ticket whose files cannot be known before the work starts, such as a bug whose cause is unknown,
  owns the directories the cause can be in; its description says what is known and how to reproduce it.
- `model:` only to move a ticket off the config's worker model.

**Acceptance criteria.** Checklist lines whose backticked text is a shell command, run from the
worktree root. Every command must exit 0 once the ticket is done.

- Prefer commands that fail before the work and pass after it: `test -f` for a file the ticket creates,
  `test ! -e` for one it removes, `grep -q` for a name or route it adds, the narrow test class it adds.
- Run tests the way the worker rules say the project runs them, narrowed to the ticket's own tests. Do
  not repeat `verify.repoChecks`: the loop appends them to every ticket's checks, so listing them again
  runs the suite twice at every verification.
- A command must pass on the integration branch with only this ticket and the ones it depends on
  merged.

**Dependencies.** Only `blocks` orders work. The ticket that produces something blocks every ticket
that uses it; parent-child is not ordering. Keep chains short: with `maxParallelWorkers` agents at a
time, a chain runs one ticket after another.

## 4. Show the draft, then create

Show the user one table before writing anything to br:

| Ticket | Files | Owned paths | Checks | Blocked by |
|---|---|---|---|---|

with the file count of every ticket, and below it anything you could not settle. Change the draft until
the user approves it. Then create each ticket under the epic, in dependency order:

```bash
id=$(br create "<title>" -t task -p 2 --parent <epic-id> --silent -d "$(cat <<'EOF'
<description>
EOF
)")
br update "$id" --design="$(cat <<'EOF'
owned_paths:
- path/to/file.kt
mode: parallel
EOF
)" --acceptance-criteria="$(cat <<'EOF'
- [ ] `test -f path/to/file.kt`
EOF
)"
br dep add "$id" <id-of-the-ticket-it-needs>
```

`--design=` and `--acceptance-criteria=` take the `=` form because their values start with `-`.

## 5. Check

```bash
epic_loop check --epic <epic-id> --config <config>
```

Every ticket must show `ok`. Then go over the table once more: no ticket past eight files, no two
parallel tickets owning the same path, every ticket green with only its blockers merged. Report the
tickets, their order and their sizes to the user, and run `br sync --flush-only`.

## Resizing tickets that exist

A ticket past eight files is split the same way: create its parts under the epic, give each its
dependencies, move every ticket that depended on the original onto the part it needs
(`br dep remove` and `br dep add`), and close the original with a reason naming its parts. Only an
`open` ticket is resized. One the loop has claimed (`in_progress` or `blocked` with a worktree) belongs
to the loop; leave it and tell the user. Tickets can be added while the loop runs: it skips a ticket
until its design and acceptance criteria are set, then dispatches it on its next pass.
