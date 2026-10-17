defmodule EpicLoop.DispatchTest do
  use ExUnit.Case, async: true
  alias EpicLoop.Coordinator

  defp t(id), do: %{id: id}

  test "an incomplete ticket is reported once, only after the grace" do
    {seen, report} = Coordinator.track_incomplete([t("a")], %{}, 1_000, 100)
    assert report == [] and seen["a"] == %{since: 1_000, reported: false}

    {seen, report} = Coordinator.track_incomplete([t("a")], seen, 1_050, 100)
    assert report == []

    {seen, report} = Coordinator.track_incomplete([t("a")], seen, 1_100, 100)
    assert report == [t("a")] and seen["a"].reported

    {_seen, report} = Coordinator.track_incomplete([t("a")], seen, 9_000, 100)
    assert report == []
  end

  test "a ticket that is complete again leaves the map, so a later gap starts a fresh grace" do
    {seen, _} = Coordinator.track_incomplete([t("a"), t("b")], %{}, 0, 100)
    {seen, _} = Coordinator.track_incomplete([t("b")], seen, 50, 100)
    assert Map.keys(seen) == ["b"]

    {seen, report} = Coordinator.track_incomplete([t("a"), t("b")], seen, 120, 100)
    assert report == [t("b")]
    assert seen["a"] == %{since: 120, reported: false}
  end

  defp k(id, status), do: %{"id" => id, "status" => status}

  test "adoption fills the free slots only, in-progress tickets before blocked ones" do
    kids = [k("b1", "blocked"), k("p1", "in_progress"), k("p2", "in_progress"), k("o1", "open"), k("c1", "closed")]
    all = fn _ -> true end
    assert Coordinator.adoptable(kids, %{}, 2, all) == ["p1", "p2"]
    assert Coordinator.adoptable(kids, %{}, 5, all) == ["p1", "p2", "b1"]
    assert Coordinator.adoptable(kids, %{"p1" => self()}, 1, all) == ["p2"]
    assert Coordinator.adoptable(kids, %{}, 0, all) == []
    assert Coordinator.adoptable(kids, %{}, -1, all) == []
  end

  test "a blocked ticket is adopted only with a worktree, and worktrees are looked up only for free slots" do
    kids = [k("b1", "blocked"), k("b2", "blocked")]
    assert Coordinator.adoptable(kids, %{}, 2, &(&1 == "b2")) == ["b2"]
    assert Coordinator.adoptable(kids, %{}, 0, fn _ -> flunk("looked up a worktree with no slot free") end) == []
  end
end
