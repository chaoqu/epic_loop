defmodule EpicLoop.Epics do
  @moduledoc """
  The epics the dashboard serves: one small file per epic in `$XDG_STATE_HOME/epic_loop/epics/`, else
  `~/.local/state/epic_loop/epics/`. Every command that names an epic and a config registers it, so
  `init`, `run`, `check` and `status` put an epic on the dashboard; `epic_loop forget` takes it off. An
  entry holds pointers, not state: the epic id, its config and its integration worktree. Everything the
  dashboard shows about an epic it reads from br, herdr, git and that worktree.

  The same folder holds `dashboard.json`, the URL and OS pid of the dashboard that is running, so `run`
  and `status` can print where to look, and `timings/`, each epic's timing record (see `EpicLoop.Timing`).
  """
  alias EpicLoop.{Sh, State}

  def root, do: Path.join(System.get_env("XDG_STATE_HOME") || Path.join(System.user_home!(), ".local/state"), "epic_loop")
  defp dir, do: Path.join(root(), "epics")
  defp file(epic), do: Path.join(dir(), slug(epic) <> ".json")

  @doc "The epic's id as a file name."
  def slug(epic), do: String.replace(epic, ~r/[^A-Za-z0-9._-]/, "_")
  defp dashboard_file, do: Path.join(root(), "dashboard.json")

  @doc """
  Record where the epic's files are. An unknown integration worktree (nil: herdr did not answer, or `init`
  has not created it) keeps the one already recorded. The file is rewritten only when something changed.
  """
  def register(epic, cfg, int_path) do
    old = get(epic) || %{}
    entry = %{"epic" => epic, "config" => cfg["configPath"], "repo" => cfg["repo"], "integration" => int_path || old["integration"]}

    if Map.take(old, Map.keys(entry)) != entry do
      File.mkdir_p!(dir())
      write(file(epic), Map.put(entry, "registered_at", old["registered_at"] || System.os_time(:millisecond)))
    end

    :ok
  rescue
    # The dashboard is a convenience: a state folder that cannot be written never stops a command.
    _ -> :ok
  end

  def get(epic), do: with(%{"epic" => _} = e <- read(file(epic)), do: e, else: (_ -> nil))

  @doc "Every registered epic, newest first."
  def list do
    # Listed, not globbed: a wildcard skips names that start with a dot, which an id may produce.
    case(File.ls(dir()), do: ({:ok, names} -> names; _ -> []))
    |> Enum.filter(&String.ends_with?(&1, ".json"))
    |> Enum.map(&read(Path.join(dir(), &1)))
    |> Enum.filter(&match?(%{"epic" => _}, &1))
    |> Enum.sort_by(&(-(&1["registered_at"] || 0)))
  end

  def forget(epic), do: File.rm(file(epic))

  @doc "Record the running dashboard's URL, with this OS process as its owner."
  def put_dashboard(url) do
    File.mkdir_p!(root())
    write(dashboard_file(), %{"url" => url, "pid" => System.pid()})
  rescue
    _ -> :ok
  end

  @doc "The running dashboard's `%{\"url\", \"pid\"}`, or nil when none is: no file, or its process is gone."
  def dashboard do
    with %{"pid" => pid} = d <- read(dashboard_file()), true <- State.alive?(pid, "epic_loop"), do: d, else: (_ -> nil)
  end

  defp read(path), do: with({:ok, raw} <- File.read(path), %{} = d <- Sh.decode(raw), do: d, else: (_ -> nil))

  defp write(path, data) do
    tmp = path <> ".tmp"
    File.write!(tmp, JSON.encode!(data))
    File.rename!(tmp, path)
  end
end
