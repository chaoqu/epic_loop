defmodule EpicLoop.Transcript do
  @moduledoc """
  Where an agent's time went, read from its Claude Code transcript once it is done. Claude keeps one
  `.jsonl` file per session under `~/.claude/projects/` (`$CLAUDE_CONFIG_DIR/projects/`), in a folder
  named after the session's directory, so a ticket's worktree names the folder that holds every
  session of the ticket: its workers, and any the person started there.

  Every gap between two consecutive entries is charged to what was pending when it began, so the parts
  add up to the session's length:

  - the model owing its next block: `think_ms` when that block is thinking or text, else the
    `model_ms` of the tool it calls, which for Write and Edit is mostly writing the file's contents;
  - a tool call in flight: that tool's `run_ms`;
  - the turn over: `idle_ms`, waiting on the loop or a person; or, when the next prompt is the
    notification of a command the agent ran in the background, that command's `run_ms`.

  Bash is split by what the command does, since a test run and a `sed -n` are different work:
  `Bash:check` (builds, tests, linters, and whatever `timing.checkCommands` matches), `Bash:wait`
  (polling with `sleep` or `until`), `Bash:write` (editing files from the shell), `Bash:read`,
  `Bash:git` and `Bash:other`.
  """
  alias EpicLoop.{Brief, Sh}

  def claude_dir, do: System.get_env("CLAUDE_CONFIG_DIR") || Path.join(System.user_home!(), ".claude")

  @doc "The folder holding the sessions Claude ran in `cwd`: the path with every other character than a letter or digit made `-`."
  def dir(cwd), do: Path.join([claude_dir(), "projects", String.replace(cwd, ~r/[^A-Za-z0-9]/, "-")])

  @doc "Every session transcript of `cwd`, oldest first."
  def sessions(cwd) do
    d = dir(cwd)

    case File.ls(d) do
      {:ok, names} -> names |> Enum.filter(&String.ends_with?(&1, ".jsonl")) |> Enum.map(&Path.join(d, &1)) |> Enum.sort_by(&mtime/1)
      _ -> []
    end
  end

  defp mtime(f), do: (case File.stat(f, time: :posix), do: ({:ok, st} -> st.mtime; _ -> 0))

  # ---------------------------------------------------------------- classifying a call
  @heredoc ~r/<<-?\s*['"]?(\w+)['"]?[^\n]*\n.*?\n\s*\1\s*(?=\n|$)/s
  @split ~r/&&|\|\||[;|\n]/
  @lead ~r/^\s*(?:[A-Za-z_][A-Za-z0-9_]*=(?:"[^"]*"|'[^']*'|\S*)\s+|(?:nohup|time|exec|env|do|then|else|timeout\s+\S+)\s+|[({!]\s*)/
  @check ~r/^(\S*checks\.sh["']?|\S*gradlew|gradle|mvn|\S*mvnw|pytest|tox|nox|tsc|vitest|jest|eslint|ruff|mypy|pyright|make|playwright|npx|(npm|pnpm|yarn|bun)\s+(test|run|exec|build|lint|ci|install)|cargo\s+(test|build|check|clippy)|go\s+(test|build|vet)|mix\s+(test|compile)|uv\s+run|python3?\s+-m\s+(pytest|mypy|ruff))(\s|$)/
  @read ~r/^(cat|sed\s+-n|head|tail|grep|egrep|rg|ls|find|wc|nl|tree|file|stat|jq|awk|less|diff|git\s+(grep|show|log|diff|status|blame|ls-files|ls-tree|rev-parse|branch))(\s|$)/
  @write ~r/(^|\s)(cat|tee)\s+(-a\s+)?>?>?\s*\S+\s*<<|\bsed\s+(-[a-zA-Z]*\s+)*-i|\bperl\s+-[a-z]*i|write_text\(|\.write\(|open\([^)]*['"][wa]['"]/
  @quoted ~r/'[^']*'|"(?:[^"\\]|\\.)*"/s
  # Commands that frame the work rather than do it: changing directory, loops, conditionals, a bare
  # assignment, a separator printed between outputs.
  @frame ~r/^(cd(\s|$)|for\s|while\s|until\s|if\s|then$|else$|fi$|done$|[A-Za-z_][A-Za-z0-9_]*=\S*$|echo(\s|$)|printf\s)/
  @wait ~r/\bsleep\b|\buntil\b|tail -f|tail -n ?0 -f/
  @launch ~r/nohup|&\s*($|\n)|\bdisown\b/

  @doc """
  What a Bash command line does. Heredoc bodies are dropped, the line is cut into its commands (at
  `&&`, `||`, `;`, `|` and newlines outside quotes), and each command is taken from its program on,
  past variable assignments and `nohup`, `timeout` and the like. Then: `wait` for a polling loop that
  launches nothing; `check` when any command runs a build, test or lint tool, or matches `extra` (a
  regex); `write` when the line edits a file (`sed -i`, a heredoc into a file, a script that writes);
  else by the first command that does the work (not `cd`, a loop or conditional keyword, a bare
  assignment or an `echo`): `read`, `git`, or `other`.
  """
  def bash_kind(cmd, extra \\ nil) do
    body = body(cmd)
    cmds = commands(cmd)
    first = Enum.find(cmds, "", &(not Regex.match?(@frame, &1)))

    cond do
      Regex.match?(@wait, body) and not Regex.match?(@launch, body) -> "wait"
      Enum.any?(cmds, &(Regex.match?(@check, &1) or (extra != nil and Regex.match?(extra, &1)))) -> "check"
      Regex.match?(@write, cmd) -> "write"
      Regex.match?(@read, first) -> "read"
      String.starts_with?(first, "git ") -> "git"
      true -> "other"
    end
  end

  @doc "The commands of a Bash line in order, each from its program on (see `bash_kind/2`)."
  def commands(cmd), do: cmd |> body() |> String.split(@split) |> Enum.map(&program/1) |> Enum.reject(&(&1 == ""))

  # The line without heredoc bodies, with separators inside quotes made spaces.
  defp body(cmd), do: Regex.replace(@heredoc, cmd, "") |> then(&Regex.replace(@quoted, &1, fn q -> String.replace(q, ~r/[|;&\n]/, " ") end))

  defp program(c), do: (case Regex.replace(@lead, c, "", global: false), do: (^c -> String.trim(c); rest -> program(rest)))

  @doc "The key a tool call's time is charged to: the tool's name, with Bash split by `bash_kind/2`."
  def key("Bash", input, extra), do: "Bash:" <> bash_kind(input["command"] || "", extra)
  def key("Task", _input, _extra), do: "Agent"
  def key(name, _input, _extra), do: name

  @doc "Which agent a session was, from its first prompt: `implementer` for one the loop briefed, else `other`."
  def role(prompt), do: if(prompt == Brief.prompt_text(), do: "implementer", else: "other")

  # ---------------------------------------------------------------- reading a session
  @doc """
  The breakdown of one session file, or nil when it holds no exchange. `extra` is the regex of
  `timing.checkCommands`, or nil.
  """
  def analyze(path, extra \\ nil) do
    events = path |> File.stream!() |> Stream.map(&event/1) |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.at)

    case events do
      [first | [_ | _] = rest] ->
        acc = walk([first | rest], extra, %{out: %{}, bg: %{}, think: 0, idle: 0, tools: %{}})
        last = List.last(events)
        assistant = Enum.filter(events, &(&1.kind == :assistant))
        span = last.at - first.at

        %{
          session: Path.basename(path, ".jsonl"),
          role: role(Enum.find_value(events, &(&1.kind == :prompt && &1.text))),
          model: Enum.find_value(assistant, & &1.model),
          start: first.at,
          ms: span,
          active_ms: span - acc.idle,
          idle_ms: acc.idle,
          think_ms: acc.think,
          tools: acc.tools,
          tool_calls: acc.tools |> Map.values() |> Enum.map(& &1.calls) |> Enum.sum(),
          prompts: Enum.count(events, &(&1.kind == :prompt)),
          peak_context: assistant |> Enum.map(& &1.context) |> Enum.max(fn -> 0 end)
        }

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  # One transcript line as an event, or nil for what does not take part: metadata, attachments other
  # than a queued prompt, and a subagent's side of the conversation.
  defp event(line) do
    with true <- String.contains?(line, ~s("timestamp")),
         %{"timestamp" => ts} = e <- Sh.decode(line),
         {:ok, dt, _} <- DateTime.from_iso8601(ts),
         false <- e["isSidechain"] == true,
         %{} = ev <- classify(e) do
      Map.put(ev, :at, DateTime.to_unix(dt, :millisecond))
    else
      _ -> nil
    end
  end

  defp classify(%{"type" => "assistant", "message" => %{} = m}) do
    u = m["usage"] || %{}
    %{kind: :assistant, id: m["id"], blocks: m["content"] || [], stop: m["stop_reason"], model: m["model"], context: (u["input_tokens"] || 0) + (u["cache_read_input_tokens"] || 0) + (u["cache_creation_input_tokens"] || 0)}
  end

  defp classify(%{"type" => "user", "message" => %{"content" => c}}) when is_binary(c), do: %{kind: :prompt, text: c}

  defp classify(%{"type" => "user", "message" => %{"content" => c}} = e) when is_list(c) do
    case for(%{"type" => "tool_result"} = b <- c, do: b["tool_use_id"]) do
      [] -> %{kind: :prompt, text: Enum.join(for(%{"type" => "text", "text" => t} <- c, do: t), "\n")}
      ids -> %{kind: :results, ids: ids, background: match?(%{"backgroundTaskId" => id} when is_binary(id), e["toolUseResult"])}
    end
  end

  # A prompt that arrived while the agent was busy, among them the notice that a background command ended.
  defp classify(%{"type" => "attachment", "attachment" => %{"type" => "queued_command", "prompt" => p}}) when is_binary(p), do: %{kind: :prompt, text: p}
  defp classify(_), do: nil

  defp walk([e, nxt | rest], extra, acc), do: walk([nxt | rest], extra, charge(note(acc, e, extra), e, nxt, max(nxt.at - e.at, 0), extra))
  defp walk(_, _extra, acc), do: acc

  # What `e` changes: the calls it starts, the calls it ends, the background commands it ends.
  defp note(acc, %{kind: :assistant, blocks: blocks}, extra) do
    Enum.reduce(blocks, acc, fn
      %{"type" => "tool_use", "id" => id, "name" => name} = b, acc ->
        k = key(name, b["input"] || %{}, extra)
        %{acc | out: Map.put(acc.out, id, k)} |> add(k, :calls, 1)

      _, acc ->
        acc
    end)
  end

  defp note(acc, %{kind: :results, ids: ids, background: bg}, _extra) do
    {done, out} = Map.split(acc.out, ids)
    %{acc | out: out, bg: if(bg, do: Map.merge(acc.bg, done), else: acc.bg)}
  end

  defp note(acc, %{kind: :prompt, text: text}, _extra), do: %{acc | bg: Map.drop(acc.bg, notified(text))}

  defp notified(text), do: Regex.scan(~r/<tool-use-id>([^<]+)<\/tool-use-id>/, text, capture: :all_but_first) |> List.flatten()

  defp charge(acc, e, nxt, gap, extra) do
    cond do
      # A turn that ended, then went on with no prompt the transcript shows, waited for something.
      nxt.kind == :assistant and e.kind == :assistant and e.stop == "end_turn" and e.id != nxt.id -> %{acc | idle: acc.idle + gap}
      nxt.kind == :assistant -> model(acc, nxt, gap, extra)
      acc.out != %{} -> run(acc, Map.values(acc.out), gap)
      e.kind == :assistant and nxt.kind == :prompt -> waited(acc, nxt, gap)
      true -> %{acc | think: acc.think + gap}
    end
  end

  defp model(acc, %{blocks: [%{"type" => "tool_use", "name" => name} = b | _]}, gap, extra), do: add(acc, key(name, b["input"] || %{}, extra), :model_ms, gap)
  defp model(acc, _nxt, gap, _extra), do: %{acc | think: acc.think + gap}

  defp run(acc, keys, gap), do: Enum.reduce(keys, acc, &add(&2, &1, :run_ms, div(gap, length(keys))))

  defp waited(acc, prompt, gap) do
    case prompt.text |> notified() |> Enum.map(&acc.bg[&1]) |> Enum.reject(&is_nil/1) do
      [] -> %{acc | idle: acc.idle + gap}
      keys -> run(acc, keys, gap)
    end
  end

  defp add(acc, k, field, n), do: %{acc | tools: Map.update(acc.tools, k, Map.put(%{calls: 0, model_ms: 0, run_ms: 0}, field, n), &Map.update!(&1, field, fn v -> v + n end))}
end
