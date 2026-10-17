defmodule EpicLoop.WorktreesTest do
  use ExUnit.Case, async: false
  alias EpicLoop.Worktrees

  @fake ~S'''
  #!/bin/sh
  case "$1 $2" in
    "worktree list") cat <<'JSON'
  {"result":{"worktrees":[
    {"path":"/repo","branch":"main","is_linked_worktree":false},
    {"path":"/wt/epic","branch":"epic/e1","is_linked_worktree":true},
    {"path":"/wt/t1","branch":"ticket/e1.1","is_linked_worktree":true},
    {"path":"/wt/detached","branch":null,"is_linked_worktree":true}
  ]}}
  JSON
    ;;
  esac
  '''

  setup do
    dir = Path.join(System.tmp_dir!(), "fake-herdr-wt-#{System.pid()}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "herdr"), @fake)
    File.chmod!(Path.join(dir, "herdr"), 0o755)
    path = System.get_env("PATH")
    System.put_env("PATH", dir <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path); File.rm_rf!(dir) end)
    :ok
  end

  test "a ticket's worktree is found by its branch" do
    assert {%{"path" => "/wt/t1"}, "branch name"} = Worktrees.find_ticket("/repo", "epic/e1", nil, "e1.1")
  end

  test "no match without a marker is nil, and the integration and main checkouts never match" do
    assert Worktrees.find_ticket("/repo", "epic/e1", nil, "e1.2") == nil
    assert Worktrees.branch("e1.1") == "ticket/e1.1"
  end
end
