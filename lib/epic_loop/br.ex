defmodule EpicLoop.Br do
  @moduledoc "beads_rust wrappers. Every call uses --json; the human format is not stable."
  alias EpicLoop.Sh

  @env [{"RUST_LOG", "error"}]

  defp first(list) when is_list(list), do: List.first(list)
  defp first(other), do: other

  defp br!(args, what) do
    r = Sh.json("br", args, env: @env)
    if r.code != 0, do: raise("#{what} failed: #{String.trim(r.err)}")
    r.json
  end

  @doc "--epic is recursive: bug children filed under closed tickets are included."
  def ready(epic), do: br!(["ready", "--epic", epic, "--limit", "0", "--json"], "br ready") || []

  def show(id), do: br!(["show", id, "--json"], "br show #{id}") |> first()

  @doc "Several issues in one call, in no particular order."
  def show_many([]), do: []
  def show_many(ids), do: List.wrap(br!(["show" | ids] ++ ["--json"], "br show #{Enum.join(ids, " ")}"))

  @doc "Every descendant (children, grandchildren, ...) through parent-child dependents."
  def descendants(id), do: descendants(id, [], MapSet.new()) |> elem(0)

  defp descendants(id, acc, seen) do
    e = show(id)

    (e["dependents"] || [])
    |> Enum.filter(&(&1["dependency_type"] == "parent-child"))
    |> Enum.reduce({acc, seen}, fn d, {acc, seen} ->
      if MapSet.member?(seen, d["id"]), do: {acc, seen}, else: descendants(d["id"], acc ++ [d], MapSet.put(seen, d["id"]))
    end)
  end

  def claim(id, actor), do: Sh.json("br", ["update", id, "--claim", "--actor", actor, "--json"], env: @env).code == 0

  def set_status(id, status, notes, actor) do
    args = ["update", id, "--status", status, "--actor", actor, "--json"] ++ if(notes, do: ["--notes", notes], else: [])
    br!(args, "br update #{id} --status #{status}")
    :ok
  end

  def add_notes(id, notes, actor), do: Sh.json("br", ["update", id, "--notes", notes, "--actor", actor, "--json"], env: @env)
  def comment(id, message, actor), do: Sh.run("br", ["comments", "add", id, "--message", message, "--actor", actor], env: @env)

  def close(id, reason, actor) do
    br!(["close", id, "--reason", reason, "--actor", actor, "--json"], "br close #{id}")
    :ok
  end

  def create(attrs) do
    args =
      ["create", attrs.title, "-t", attrs[:type] || "task", "-p", Integer.to_string(attrs[:priority] || 2), "--parent", attrs.parent, "--silent", "-d", attrs.description, "--actor", attrs.actor] ++
        if(attrs[:deps], do: ["--deps", attrs.deps], else: []) ++ if(attrs[:labels], do: ["-l", attrs.labels], else: [])

    r = Sh.run("br", args, env: @env)
    if r.code != 0, do: raise("br create failed: #{String.trim(r.err)}")
    String.trim(r.out)
  end

  @doc "design / acceptance values may start with \"-\", so they go in --flag=value form."
  def set_fields(id, design, acceptance, actor) do
    args = ["update", id, "--actor", actor, "--json"] ++ if(design, do: ["--design=" <> design], else: []) ++ if(acceptance, do: ["--acceptance-criteria=" <> acceptance], else: [])
    br!(args, "br update #{id} fields")
    :ok
  end
end
