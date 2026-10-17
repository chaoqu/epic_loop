defmodule EpicLoop.Times do
  @moduledoc """
  `epic_loop times`: the epic's timing record (see `EpicLoop.Timing`) as text. For the epic: its runs
  and its own stages, every ticket stage summed, where the agents' time went, and one row per ticket.
  For one ticket: its stages in order, with each check and review, and each agent session's tools.

  An agent's time falls in thinking (thinking and text), reading (Read, Grep, Glob and reading shell
  commands), writing (Write and Edit, including the model writing the contents, and editing from the
  shell), checks (builds and
  tests, and waiting on them), and other tools; each tool's share counts the model writing the call and
  the call running.

  Where a session's record has its token use (see `EpicLoop.Usage`), the report adds the tokens, the
  context peak, and what filled the context: the model's own output, prompts, and the tools and files
  whose results added the most.
  """

  @ticket_stages ~w(setup implement fix human merge)
  @merge_steps ~w(queue rebase verify review merge-checks)
  @groups [{"reading", ~w(Read Grep Glob Bash:read)}, {"writing", ~w(Write Edit MultiEdit NotebookEdit Bash:write)}, {"checks", ~w(Bash:check Bash:wait)}]

  def report(records, ticket \\ nil)
  def report([], _ticket), do: "nothing recorded yet\n"
  def report(records, nil), do: epic(records)
  def report(records, ticket), do: ticket(records, ticket)

  # ---------------------------------------------------------------- the epic
  defp epic(records) do
    {spans, agents} = split(records)
    runs = Enum.filter(spans, &(&1["stage"] == "run"))
    own = Enum.filter(spans, &(&1["ticket"] == nil and &1["stage"] != "run"))
    tickets = spans |> Enum.map(& &1["ticket"]) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    stages = Enum.filter(spans, &(&1["ticket"] != nil))

    [
      "Epic #{hd(records)["epic"]}: #{length(runs)} run(s), #{fmt(sum(runs))} running#{case List.last(runs), do: (nil -> ""; r -> ", last #{r["result"]}")}\n",
      if(own != [], do: "  " <> Enum.map_join(group_by_stage(own), " · ", fn {st, rs} -> "#{st} #{fmt(sum(rs))}" end) <> "\n", else: ""),
      "\nTicket stages, summed over #{length(tickets)} ticket(s)\n",
      stage_table(stages),
      agent_summary(agents),
      token_summary(agents),
      ticket_rows(tickets, stages, agents)
    ]
    |> IO.iodata_to_binary()
  end

  defp stage_table(stages) do
    total = stages |> Enum.filter(&(&1["stage"] in @ticket_stages)) |> sum()

    Enum.map(@ticket_stages, fn st ->
      t = stages |> Enum.filter(&(&1["stage"] == st)) |> sum()
      steps = if st == "merge", do: "   " <> Enum.map_join(@merge_steps, " · ", fn m -> "#{m} #{fmt(stages |> Enum.filter(&(&1["stage"] == m)) |> sum())}" end), else: ""
      line("  #{pad(st, 11)}#{lpad(dash(t), 9)}#{lpad(pct(t, total), 6)}#{if t > 0, do: steps, else: ""}")
    end)
  end

  defp agent_summary([]), do: "\nAgents: no transcripts recorded yet; a ticket's are read when it merges\n"

  defp agent_summary(agents) do
    working = Enum.sum(Enum.map(agents, & &1["active_ms"]))
    idle = Enum.sum(Enum.map(agents, & &1["idle_ms"]))
    tools = merge_tools(agents)

    [
      "\nAgents, from #{length(agents)} session(s): #{fmt(working)} working, #{fmt(idle)} waiting on the loop or a person\n",
      "  #{pad("thinking", 11)}#{lpad(fmt(Enum.sum(Enum.map(agents, & &1["think_ms"]))), 9)}#{lpad(pct(Enum.sum(Enum.map(agents, & &1["think_ms"])), working), 6)}\n",
      Enum.map(group_names(), fn g ->
        members = tools |> Enum.filter(fn {k, _} -> group(k) == g end) |> Enum.sort_by(fn {_, v} -> -tool_ms(v) end)
        t = members |> Enum.map(fn {_, v} -> tool_ms(v) end) |> Enum.sum()
        line("  #{pad(g, 11)}#{lpad(fmt(t), 9)}#{lpad(pct(t, working), 6)}   #{tool_list(members)}")
      end)
    ]
  end

  defp token_summary(agents) do
    case Enum.filter(agents, &is_map(&1["usage"])) do
      [] -> []
      with_usage ->
        u = with_usage |> Enum.map(& &1["usage"]) |> merge_usage()
        ["\nTokens, from #{length(with_usage)} session(s)\n" | usage_lines(u, "  ")]
    end
  end

  # Several sessions' usage as one: tokens and fills added up, the highest peak, and the tools and
  # files of each session's record (its top twenty) added up.
  defp merge_usage(us) do
    sum = fn key, name -> us |> Enum.flat_map(&(&1[key] || [])) |> Enum.group_by(& &1[name]) |> Enum.map(fn {n, xs} -> Enum.reduce(xs, %{name => n}, fn x, acc -> Map.merge(acc, Map.delete(x, name), fn _, a, b -> a + b end) end) end) end
    add = fn key -> us |> Enum.map(&(&1[key] || %{})) |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _, a, b -> a + b end)) end
    %{"tokens" => add.("tokens"), "filled" => add.("filled"), "peak" => us |> Enum.map(&(&1["peak"] || 0)) |> Enum.max(), "tools" => sum.("tools", "tool"), "files" => sum.("files", "path")}
  end

  defp usage_lines(u, indent) do
    t = u["tokens"] || %{}
    f = u["filled"] || %{}
    top = fn list, name, unit -> list |> Enum.sort_by(&(-&1["tokens"])) |> Enum.take(6) |> Enum.map_join(" · ", &"#{&1[name]} #{tok(&1["tokens"])} (#{&1[unit]})") end

    [
      "#{indent}#{tok(t["output"])} output, #{tok(t["input"])} input, #{tok(t["cache_read"])} cache read, #{tok(t["cache_write"])} cache write; context peak #{tok(u["peak"])}\n",
      "#{indent}context filled by: model output #{tok(f["model"])} · prompts #{tok(f["prompts"])} · #{top.(u["tools"] || [], "tool", "calls")}\n",
      if((u["files"] || []) != [], do: "#{indent}files read most: #{top.(u["files"], "path", "reads")}\n", else: "")
    ]
  end

  @doc "A token count as 812, 34k or 1.2M."
  def tok(nil), do: "0"
  def tok(n) when n >= 1_000_000, do: "#{Float.round(n / 1_000_000, 1)}M"
  def tok(n) when n >= 1000, do: "#{round(n / 1000)}k"
  def tok(n), do: "#{n}"

  defp ticket_rows([], _stages, _agents), do: []

  defp ticket_rows(tickets, stages, agents) do
    head = "  #{pad("ticket", 30)}" <> Enum.map_join(["total" | @ticket_stages -- ["setup"]], "", &lpad(&1, 10)) <> lpad("working", 10) <> Enum.map_join(["thinking" | group_names()], "", &lpad(&1, 9)) <> "\n"

    rows =
      Enum.map(tickets, fn id ->
        mine = Enum.filter(stages, &(&1["ticket"] == id))
        theirs = Enum.filter(agents, &(&1["ticket"] == id))
        tools = merge_tools(theirs)
        by_stage = fn st -> mine |> Enum.filter(&(&1["stage"] == st)) |> sum() end
        grouped = Enum.map(group_names(), fn g -> tools |> Enum.filter(fn {k, _} -> group(k) == g end) |> Enum.map(fn {_, v} -> tool_ms(v) end) |> Enum.sum() end)

        "  #{pad(id, 30)}" <> lpad(fmt(mine |> Enum.filter(&(&1["stage"] in @ticket_stages)) |> sum()), 10) <>
          Enum.map_join(@ticket_stages -- ["setup"], "", &lpad(dash(by_stage.(&1)), 10)) <>
          if(theirs == [], do: lpad("-", 10), else: lpad(fmt(Enum.sum(Enum.map(theirs, & &1["active_ms"]))), 10) <> Enum.map_join([Enum.sum(Enum.map(theirs, & &1["think_ms"])) | grouped], "", &lpad(fmt(&1), 9))) <> "\n"
      end)

    ["\nPer ticket\n", head | rows]
  end

  # ---------------------------------------------------------------- one ticket
  defp ticket(records, id) do
    {spans, agents} = split(Enum.filter(records, &(&1["ticket"] == id)))

    if spans == [] and agents == [] do
      "nothing recorded for #{id}\n"
    else
      title = Enum.find_value(spans, & &1["title"])

      [
        "Ticket #{id}#{if title, do: ": #{title}", else: ""}\n\nStages\n",
        spans |> Enum.sort_by(& &1["start"]) |> Enum.map(&span_line/1),
        if(agents == [], do: "\nAgents: no transcripts recorded yet; they are read when the ticket merges\n", else: ["\nAgents\n" | Enum.map(agents, &agent_lines/1)])
      ]
      |> IO.iodata_to_binary()
    end
  end

  defp span_line(r) do
    indent = if r["stage"] in @merge_steps, do: "    ", else: "  "
    line("#{clock(r["start"])}#{indent}#{pad(r["stage"], 14 - String.length(indent))}#{lpad(fmt(r["ms"]), 9)}   #{detail(r)}")
  end

  defp detail(%{"stage" => "implement"} = r), do: join(["attempt #{r["attempt"]}", r["model"], r["adopted"] && "adopted"])
  defp detail(%{"stage" => "fix"} = r), do: join(["after #{r["after"]}", "attempt #{r["attempt"]}", r["review_round"] not in [nil, 0] && "review round #{r["review_round"]}"])
  defp detail(%{"stage" => "human"} = r), do: join([r["why"], r["from"] && "during #{r["from"]}", r["adopted"] && "adopted"])
  defp detail(%{"stage" => "review"} = r), do: join(["round #{r["round"]}", r["blockers"] && "#{r["blockers"]} blockers, #{r["warnings"]} warnings", r["model"]])
  defp detail(%{"stage" => "rebase"} = r), do: to_string(r["result"])
  defp detail(%{"stage" => st} = r) when st in ["verify", "merge-checks"], do: join([if(r["ok"], do: "passed", else: "failed") | Enum.map(r["checks"] || [], &"#{short(&1["cmd"])} #{fmt(&1["ms"])}#{if &1["code"] != 0, do: " (exit #{&1["code"]})", else: ""}")])
  defp detail(_), do: ""

  defp agent_lines(a) do
    tools = a["tools"] |> Enum.sort_by(fn {_, v} -> -tool_ms(v) end)

    groups =
      ["thinking #{fmt(a["think_ms"])}" | Enum.map(group_names(), fn g -> "#{g} #{fmt(tools |> Enum.filter(fn {k, _} -> group(k) == g end) |> Enum.map(fn {_, v} -> tool_ms(v) end) |> Enum.sum())}" end)]

    [
      "  #{clock(a["start"])}  #{a["role"]} #{String.slice(a["session"], 0, 8)}  #{a["model"]}  #{fmt(a["active_ms"])} working, #{fmt(a["idle_ms"])} waiting, #{a["tool_calls"]} calls, #{a["prompts"]} prompts, context peak #{div(a["peak_context"] || 0, 1000)}k\n",
      "    #{Enum.join(groups, " · ")}\n",
      "    #{tool_list(tools)}\n",
      if(is_map(a["usage"]), do: usage_lines(a["usage"], "    "), else: [])
    ]
  end

  # ---------------------------------------------------------------- helpers
  # Spans, and the latest record of each agent session.
  defp split(records) do
    {agents, spans} = Enum.split_with(records, &(&1["stage"] == "agent"))
    latest = agents |> Enum.reduce(%{}, &Map.put(&2, &1["session"], &1)) |> Map.values() |> Enum.sort_by(& &1["start"])
    {spans, latest}
  end

  defp group_names, do: Enum.map(@groups, &elem(&1, 0)) ++ ["other"]
  def group(key), do: Enum.find_value(@groups, "other", fn {g, keys} -> if key in keys, do: g end)

  defp merge_tools(agents), do: Enum.reduce(agents, %{}, fn a, acc -> Map.merge(acc, a["tools"] || %{}, fn _, x, y -> Map.merge(x, y, fn _, p, q -> p + q end) end) end)
  defp tool_ms(v), do: (v["model_ms"] || 0) + (v["run_ms"] || 0)
  # The tools that took a second or more, longest first, with their calls; six at most.
  defp tool_list(tools) do
    {shown, rest} = tools |> Enum.filter(fn {_, v} -> tool_ms(v) >= 1000 end) |> Enum.split(6)
    Enum.map_join(shown, " · ", fn {k, v} -> "#{k} #{fmt(tool_ms(v))} (#{v["calls"]})" end) <> if(rest != [], do: " · #{length(rest)} more", else: "")
  end

  defp line(text), do: String.trim_trailing(text) <> "\n"
  defp group_by_stage(spans), do: spans |> Enum.group_by(& &1["stage"]) |> Enum.sort_by(fn {_, rs} -> hd(rs)["start"] end)
  defp sum(rs), do: rs |> Enum.map(&(&1["ms"] || 0)) |> Enum.sum()
  defp join(parts), do: parts |> Enum.filter(&(&1 not in [nil, false, ""])) |> Enum.join(", ")
  defp short(cmd), do: if(String.length(cmd) > 50, do: String.slice(cmd, 0, 47) <> "...", else: cmd)
  defp pad(s, n), do: String.pad_trailing(to_string(s), n)
  defp lpad(s, n), do: String.pad_leading(to_string(s), n)
  defp pct(t, total) when t == 0 or total == 0, do: ""
  defp pct(t, total), do: "#{round(100 * t / total)}%"
  defp dash(0), do: "-"
  defp dash(ms), do: fmt(ms)

  # When, in local time: month-day hour:minute.
  defp clock(nil), do: String.duplicate(" ", 11)

  defp clock(ms) do
    {{_, mo, d}, {h, mi, _}} = :calendar.system_time_to_local_time(ms, :millisecond)
    "#{two(mo)}-#{two(d)} #{two(h)}:#{two(mi)}"
  end

  @doc "A length in ms as m:ss, or h:mm:ss from an hour."
  def fmt(ms) do
    s = div(ms || 0, 1000)
    {h, m, sec} = {div(s, 3600), div(rem(s, 3600), 60), rem(s, 60)}
    if h > 0, do: "#{h}:#{two(m)}:#{two(sec)}", else: "#{m}:#{two(sec)}"
  end

  defp two(n), do: String.pad_leading(Integer.to_string(n), 2, "0")
end
