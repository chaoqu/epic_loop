defmodule EpicLoop.Usage do
  @moduledoc """
  What a Claude session spent in tokens and what filled its context, read from its transcript (see
  `EpicLoop.Transcript` for where a worktree's transcripts are).

  - `tokens`: what the API counted over the session: `input` (uncached), `cache_read`, `cache_write`
    and `output`, each request counted once.
  - `context`: the context of the latest request, and `peak`, the largest of any.
  - What filled the context: a request's context, less the previous request's, is what was added
    between them: first the previous request's own output (thinking, text, tool calls), which counts
    as `model`, then whatever arrived before the next request. That rest is split between the tool
    results and prompts that arrived, by their size: by tool (`tools`, with Bash split as
    `EpicLoop.Transcript.key/3` does) and, for the results of reads (Read, and `cat`, `head`, `tail`,
    `nl` and `sed -n` in Bash), by file (`files`). A request after nothing but prompts adds to
    `prompts`: the brief, answers, nudges, reminders. A compaction shrinks the context and adds nothing.

  `read/4` continues from where the previous read of the same state stopped, so a running agent's
  transcript is read once, a little at a time. `cached/3` keeps those states in the dashboard's table.
  """
  alias EpicLoop.{Sh, Transcript}

  @table :epic_loop_usage
  @window 1_000_000
  @readers ~w(cat head tail nl less bat)

  @doc "The context window the shares are of: every Claude model a worker runs on has a 1M-token window."
  def window, do: @window

  def new(root),
    do: %{root: root, offset: 0, last_id: nil, last: nil, pending: [], calls: %{}, cwd: "", model_id: nil,
      tokens: %{input: 0, cache_read: 0, cache_write: 0, output: 0}, context: 0, peak: 0, model: 0, prompts: 0, tools: %{}, files: %{}}

  @doc "Create the dashboard's table of states, one per transcript, owned by the calling process."
  def table, do: if(:ets.whereis(@table) == :undefined, do: :ets.new(@table, [:named_table, :public, :set]))

  @doc "The state of the transcript at `path`, read on from the table's copy when there is one."
  def cached(path, root, extra) do
    if :ets.whereis(@table) == :undefined do
      read(path, root, extra)
    else
      prev = case :ets.lookup(@table, path), do: ([{_, st}] -> st; _ -> nil)
      st = read(path, root, extra, prev)
      :ets.insert(@table, {path, st})
      st
    end
  end

  @doc "Read the transcript from where `state` stopped (from the start without one, or when the file shrank)."
  def read(path, root, extra, state \\ nil) do
    st = if state && state.root == root, do: state, else: new(root)

    case File.stat(path) do
      {:ok, %{size: size}} when size > st.offset -> consume(path, st, extra)
      {:ok, %{size: size}} when size < st.offset -> consume(path, new(root), extra)
      _ -> st
    end
  end

  # Whole lines only: a line still being written stays for the next read.
  defp consume(path, st, extra) do
    {:ok, io} = File.open(path, [:read, :binary])

    try do
      :file.position(io, st.offset)
      data = IO.binread(io, :eof)
      data = if is_binary(data), do: data, else: ""

      case :binary.matches(data, "\n") do
        [] -> st
        ms ->
          {pos, 1} = List.last(ms)
          lines = binary_part(data, 0, pos) |> String.split("\n")
          Enum.reduce(lines, %{st | offset: st.offset + pos + 1}, &line(&1, &2, extra))
      end
    after
      File.close(io)
    end
  end

  defp line(text, st, extra) do
    case Sh.decode(text) do
      %{"isSidechain" => true} -> st
      %{"type" => "assistant", "message" => %{} = m} -> assistant(st, m, extra)
      %{"type" => "user", "message" => %{"content" => c}} when is_binary(c) -> pend(st, :prompts, [], byte_size(c))
      %{"type" => "user", "message" => %{"content" => c}} when is_list(c) -> user(st, c)
      %{"type" => "attachment", "attachment" => %{"type" => "queued_command", "prompt" => p}} when is_binary(p) -> pend(st, :prompts, [], byte_size(p))
      _ -> st
    end
  end

  # A request's first entry carries its usage; the other blocks of the same response repeat it.
  defp assistant(st, m, extra) do
    st = if m["id"] != st.last_id and is_map(m["usage"]), do: request(st, m), else: st
    Enum.reduce(m["content"] || [], st, fn
      %{"type" => "tool_use", "id" => id, "name" => name} = b, st -> call(st, id, name, b["input"] || %{}, extra)
      _, st -> st
    end)
  end

  defp request(st, m) do
    u = m["usage"]
    ctx = (u["input_tokens"] || 0) + (u["cache_read_input_tokens"] || 0) + (u["cache_creation_input_tokens"] || 0)
    out = u["output_tokens"] || 0
    st = if st.last, do: fill(st, ctx - st.last.context, st.last.output), else: st

    t = st.tokens
    tokens = %{input: t.input + (u["input_tokens"] || 0), cache_read: t.cache_read + (u["cache_read_input_tokens"] || 0), cache_write: t.cache_write + (u["cache_creation_input_tokens"] || 0), output: t.output + out}
    %{st | last_id: m["id"], last: %{context: ctx, output: out}, pending: [], tokens: tokens, context: ctx, peak: max(st.peak, ctx), model_id: st.model_id || m["model"]}
  end

  # What the context grew by: the model's own output first, the rest split by size between what arrived.
  defp fill(st, delta, _out) when delta <= 0, do: st

  defp fill(st, delta, out) do
    own = min(out, delta)
    rest = delta - own
    st = %{st | model: st.model + own}

    case st.pending do
      [] -> %{st | prompts: st.prompts + rest}
      pending ->
        total = pending |> Enum.map(&elem(&1, 2)) |> Enum.sum() |> max(1)

        Enum.reduce(pending, st, fn {key, files, size}, st ->
          share = div(rest * size, total)

          case key do
            :prompts -> %{st | prompts: st.prompts + share}
            key -> st |> bump(:tools, key, :tokens, share) |> then(fn st -> Enum.reduce(files, st, &bump(&2, :files, &1, :tokens, div(share, length(files)))) end)
          end
        end)
    end
  end

  defp call(st, id, name, input, extra) do
    key = Transcript.key(name, input, extra)
    {files, cwd} = files(name, input, st.cwd, st.root)
    st = %{st | calls: Map.put(st.calls, id, {key, files}), cwd: cwd} |> bump(:tools, key, :calls, 1)
    Enum.reduce(files, st, &bump(&2, :files, &1, :reads, 1))
  end

  defp user(st, blocks) do
    Enum.reduce(blocks, st, fn
      %{"type" => "tool_result", "tool_use_id" => id} = b, st ->
        case Map.pop(st.calls, id) do
          {{key, files}, calls} -> pend(%{st | calls: calls}, key, files, byte_size(JSON.encode!(b["content"] || "")))
          {nil, _} -> st
        end

      %{"type" => "text", "text" => t}, st ->
        pend(st, :prompts, [], byte_size(t))

      _, st ->
        st
    end)
  end

  defp pend(st, key, files, size), do: %{st | pending: [{key, files, max(size, 1)} | st.pending]}

  defp bump(st, field, key, stat, n) do
    Map.update!(st, field, fn m -> Map.update(m, key, Map.put(%{calls: 0, reads: 0, tokens: 0}, stat, n), &Map.update!(&1, stat, fn v -> v + n end)) end)
  end

  # ---------------------------------------------------------------- which files a call reads
  @doc """
  The files a call reads, relative to `root` when inside it, and the Bash working directory after it:
  Claude keeps a `cd` from one Bash call to the next, unless it leaves the worktree.
  """
  def files("Read", %{"file_path" => p}, cwd, root) when is_binary(p), do: {[rel(p, root)], cwd}

  def files("Bash", %{"command" => cmd}, cwd, root) when is_binary(cmd) do
    {files, dir} =
      Enum.reduce(Transcript.commands(cmd), {[], cwd}, fn c, {acc, dir} ->
        case String.split(c) do
          ["cd"] -> {acc, ""}
          ["cd", d | _] -> {acc, cd(dir, unquote_arg(d), root)}
          [prog | args] when prog in @readers -> {acc ++ paths(args, dir, root), dir}
          ["sed", "-n", _script | args] -> {acc ++ paths(args, dir, root), dir}
          _ -> {acc, dir}
        end
      end)

    # Claude puts the shell back in the worktree when a command leaves it there outside.
    {Enum.uniq(files), if(String.starts_with?(dir, "/"), do: "", else: dir)}
  end

  def files(_name, _input, cwd, _root), do: {[], cwd}

  # Arguments that name a file: no options, no redirections or what they point at, no unknown variables.
  defp paths(args, dir, root) do
    args
    |> Enum.reduce({[], false}, fn a, {acc, skip} ->
      cond do
        skip -> {acc, false}
        a in [">", ">>", "<", "2>"] -> {acc, true}
        String.starts_with?(a, "-") or String.contains?(a, ">") or String.starts_with?(a, "<") -> {acc, false}
        true -> {[a | acc], false}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.map(&unquote_arg/1)
    |> Enum.map(&String.replace(&1, ~r/^(\$HOME|\$\{HOME\}|~)(?=\/|$)/, System.user_home!()))
    |> Enum.filter(&(&1 != "" and not String.contains?(&1, "$") and String.match?(&1, ~r/[\/.]/)))
    |> Enum.map(&rel(Path.expand(&1, base(dir, root)), root))
  end

  # The working directory as an absolute path; `dir` is relative to the worktree, or absolute outside it.
  defp base(dir, root), do: if(String.starts_with?(dir, "/"), do: dir, else: Path.join(root, dir))

  defp cd(dir, d, root) do
    if String.contains?(d, "$") do
      ""
    else
      abs = d |> String.replace(~r/^~(?=\/|$)/, System.user_home!()) |> Path.expand(base(dir, root))

      cond do
        abs == root -> ""
        String.starts_with?(abs, root <> "/") -> String.replace_prefix(abs, root <> "/", "")
        true -> abs
      end
    end
  end

  defp unquote_arg(a), do: String.trim(a, "\"") |> String.trim("'")

  @doc """
  A path relative to `root` when inside it, with the home folder as `~` otherwise. A tool output too long
  for the context, which Claude saves to a file and the agent then reads, is `(saved tool output) <name>`,
  and a file in the agent's scratchpad is `(scratchpad) <path>`.
  """
  def rel(p, root) do
    p = Path.expand(p)

    cond do
      String.match?(p, ~r{/projects/[^/]+/[^/]+/tool-results/[^/]+$}) -> "(saved tool output) " <> Path.basename(p)
      m = Regex.run(~r{/claude-\d+/[^/]+/[^/]+/scratchpad/(.+)$}, p) -> "(scratchpad) " <> List.last(m)
      p == root -> "."
      String.starts_with?(p, root <> "/") -> String.replace_prefix(p, root <> "/", "")
      String.starts_with?(p, System.user_home!() <> "/") -> "~/" <> String.replace_prefix(p, System.user_home!() <> "/", "")
      true -> p
    end
  end

  # ---------------------------------------------------------------- summaries
  @doc "Several sessions as one: tokens, fills, tools and files added up; context from the latest; the highest peak."
  def combine([]), do: nil

  def combine(states) do
    add = fn a, b -> Map.merge(a, b, fn _, x, y -> Map.merge(x, y, fn _, p, q -> p + q end) end) end

    Enum.reduce(states, fn st, acc ->
      %{acc | tokens: Map.merge(acc.tokens, st.tokens, fn _, a, b -> a + b end), context: st.context, peak: max(acc.peak, st.peak),
        model: acc.model + st.model, prompts: acc.prompts + st.prompts, tools: add.(acc.tools, st.tools), files: add.(acc.files, st.files), model_id: st.model_id || acc.model_id}
    end)
  end

  @doc "A state as the dashboard and the timing record keep it, with the `top` tools and files by tokens."
  def summary(nil, _top), do: nil

  def summary(st, top) do
    rank = fn m, k -> m |> Enum.sort_by(fn {_, v} -> -v.tokens end) |> Enum.take(top) |> Enum.map(fn {name, v} -> Map.put(v, k, name) end) end

    %{
      model: st.model_id, tokens: st.tokens, context: st.context, peak: st.peak, window: @window,
      filled: %{model: st.model, prompts: st.prompts, tools: st.tools |> Map.values() |> Enum.map(& &1.tokens) |> Enum.sum()},
      tools: rank.(st.tools, :tool) |> Enum.map(&Map.delete(&1, :reads)), files: rank.(Map.reject(st.files, fn {_, v} -> v.tokens == 0 and v.reads == 0 end), :path) |> Enum.map(&Map.delete(&1, :calls)),
      tool_count: map_size(st.tools), file_count: map_size(st.files)
    }
  end

  @doc "Every session in the ticket's worktree as one summary, or nil when it has none; the latest session gives the context."
  def ticket(wt, extra, top \\ 6) do
    case Transcript.sessions(wt) do
      [] -> nil
      files -> files |> Enum.map(&cached(&1, wt, extra)) |> combine() |> summary(top) |> Map.put(:sessions, length(files))
    end
  end
end
