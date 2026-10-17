defmodule EpicLoop.EpicsTest do
  # XDG_STATE_HOME is process-wide, so these tests do not run alongside the others.
  use ExUnit.Case, async: false
  alias EpicLoop.Epics

  setup do
    dir = Path.join(System.tmp_dir!(), "epics-#{System.unique_integer([:positive])}")
    old = System.get_env("XDG_STATE_HOME")
    System.put_env("XDG_STATE_HOME", dir)
    on_exit(fn -> if(old, do: System.put_env("XDG_STATE_HOME", old), else: System.delete_env("XDG_STATE_HOME")); File.rm_rf!(dir) end)
    %{dir: dir}
  end

  defp cfg(n), do: %{"configPath" => "/cfg/#{n}.json", "repo" => "/repo/#{n}"}

  test "an epic is registered with where its files are, listed, and forgotten", %{dir: dir} do
    assert Epics.list() == []
    Epics.register("e1", cfg(1), "/wt/e1")
    assert %{"epic" => "e1", "config" => "/cfg/1.json", "repo" => "/repo/1", "integration" => "/wt/e1", "registered_at" => _} = Epics.get("e1")
    assert File.exists?(Path.join(dir, "epic_loop/epics/e1.json"))
    Epics.register("e2", cfg(2), nil)
    assert Enum.map(Epics.list(), & &1["epic"]) |> Enum.sort() == ["e1", "e2"]
    assert Epics.forget("e1") == :ok
    assert Epics.get("e1") == nil and Enum.map(Epics.list(), & &1["epic"]) == ["e2"]
    assert Epics.forget("e1") == {:error, :enoent}
  end

  test "an unknown integration worktree keeps the recorded one, and the first registration time stays" do
    Epics.register("e1", cfg(1), "/wt/e1")
    first = Epics.get("e1")["registered_at"]
    Epics.register("e1", cfg(1), nil)
    assert Epics.get("e1")["integration"] == "/wt/e1"
    Epics.register("e1", cfg(3), "/wt/moved")
    assert %{"config" => "/cfg/3.json", "integration" => "/wt/moved", "registered_at" => ^first} = Epics.get("e1")
  end

  test "an id is a safe file name, and other files in the folder are not epics", %{dir: dir} do
    Epics.register("../e/1", cfg(1), nil)
    assert File.exists?(Path.join(dir, "epic_loop/epics/.._e_1.json"))
    assert Epics.get("../e/1")["epic"] == "../e/1"
    File.write!(Path.join(dir, "epic_loop/epics/junk.json"), "not json")
    assert Enum.map(Epics.list(), & &1["epic"]) == ["../e/1"]
  end

  test "the running dashboard is the recorded one only while its process lives" do
    assert Epics.dashboard() == nil
    Epics.put_dashboard("http://127.0.0.1:4040/")
    # The test VM's command line has no "epic_loop", so it does not count as a dashboard process.
    assert Epics.dashboard() == nil
    File.write!(Path.join(Epics.root(), "dashboard.json"), JSON.encode!(%{"url" => "http://127.0.0.1:4040/", "pid" => "99999999"}))
    assert Epics.dashboard() == nil
  end
end
