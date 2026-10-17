defmodule EpicLoop.Tickets do
  @moduledoc """
  The ticket metadata convention.

      design:
        owned_paths:
        - research/herdr/
        mode: parallel | serial
        model: sonnet | opus            (optional)
      acceptance_criteria: checklist lines whose backticked text is a shell command
        - [ ] `test -s research/herdr/findings.md`
  """

  def parse(issue) do
    {owned, mode, model} = parse_design(issue["design"] || "")

    checks =
      Regex.scan(~r/`([^`]+)`/, issue["acceptance_criteria"] || "")
      |> Enum.map(fn [_, c] -> c end)

    %{
      id: issue["id"],
      title: issue["title"],
      description: issue["description"] || "",
      notes: issue["notes"] || "",
      status: issue["status"],
      owned: owned,
      mode: mode,
      model: model,
      checks: checks,
      raw: issue
    }
  end

  defp parse_design(design) do
    design
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reduce({[], "parallel", nil, false}, fn line, {owned, mode, model, in_owned} ->
      cond do
        Regex.match?(~r/^owned_paths:/i, line) -> {owned, mode, model, true}
        in_owned and Regex.match?(~r/^-\s+/, line) -> {owned ++ [String.replace(line, ~r/^-\s+/, "")], mode, model, true}
        Regex.match?(~r/^mode:/i, line) -> {owned, value(line), model, false}
        Regex.match?(~r/^model:/i, line) -> {owned, mode, value(line), false}
        line == "" -> {owned, mode, model, in_owned}
        true -> {owned, mode, model, false}
      end
    end)
    |> then(fn {owned, mode, model, _} -> {owned, if(mode == "serial", do: "serial", else: "parallel"), model} end)
  end

  defp value(line), do: line |> String.split(":", parts: 2) |> List.last() |> String.trim() |> String.downcase()

  def validate(t) do
    []
    |> then(&if(t.owned == [], do: ["no owned_paths in design" | &1], else: &1))
    |> then(&if(t.checks == [], do: ["no backticked acceptance commands" | &1], else: &1))
    |> Enum.reverse()
  end

  defp norm(p), do: (p |> String.replace_prefix("./", "") |> String.trim_trailing("/")) <> "/"

  def overlaps?(a, b) do
    Enum.any?(a.owned, fn x -> Enum.any?(b.owned, fn y -> String.starts_with?(norm(x), norm(y)) or String.starts_with?(norm(y), norm(x)) end) end)
  end

  def path_owned?(path, owned), do: Enum.any?(owned, fn o -> path == o or String.starts_with?(path, norm(o)) end)
end
