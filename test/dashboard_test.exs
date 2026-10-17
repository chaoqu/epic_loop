defmodule EpicLoop.DashboardTest do
  # A fake `br` and `herdr` first on PATH stand in for beads and herdr, and XDG_STATE_HOME points the
  # registry at a temp folder. Requests go over a raw socket so the test controls the Host header.
  use ExUnit.Case, async: false
  alias EpicLoop.{Dashboard, Epics}

  @br ~S'''
  #!/bin/sh
  case "$1" in
    show)
      if [ "$2" = "e1" ]; then
        printf '%s\n' '[{"id":"e1","title":"The epic","status":"open","issue_type":"epic","dependents":[{"id":"e1.1","dependency_type":"parent-child"}]}]'
      else
        printf '%s\n' '[{"id":"e1.1","title":"One ticket","status":"open","issue_type":"task","design":"owned_paths:\n- a/\nmode: parallel","acceptance_criteria":"- [ ] `true`","dependents":[]}]'
      fi ;;
    ready) echo '[{"id":"e1.1"}]' ;;
  esac
  '''

  @herdr ~S'''
  #!/bin/sh
  case "$1 $2" in
    "worktree list") echo '{"result":{"worktrees":[]}}' ;;
    "agent list") echo '{"result":{"agents":[]}}' ;;
  esac
  '''

  setup do
    dir = Path.join(System.tmp_dir!(), "fake-dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    for {name, body} <- [{"br", @br}, {"herdr", @herdr}], do: (File.write!(Path.join(dir, name), body); File.chmod!(Path.join(dir, name), 0o755))
    config = Path.join(dir, "config.json")
    File.write!(config, JSON.encode!(%{"repo" => dir, "baseBranch" => "main", "pollIntervalMs" => 15_000, "dispatch" => %{"maxParallelWorkers" => 2}}))
    {path, state} = {System.get_env("PATH"), System.get_env("XDG_STATE_HOME")}
    System.put_env("PATH", dir <> ":" <> path)
    System.put_env("XDG_STATE_HOME", Path.join(dir, "state"))
    Epics.register("e1", %{"configPath" => config, "repo" => dir}, nil)
    pid = start_supervised!({Dashboard, port: 0})
    port = :sys.get_state(pid).url |> URI.parse() |> Map.fetch!(:port)

    on_exit(fn ->
      System.put_env("PATH", path)
      if state, do: System.put_env("XDG_STATE_HOME", state), else: System.delete_env("XDG_STATE_HOME")
      File.rm_rf!(dir)
    end)

    %{port: port}
  end

  defp request(port, method, path, host \\ nil) do
    {:ok, s} = :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false])
    :ok = :gen_tcp.send(s, "#{method} #{path} HTTP/1.1\r\nHost: #{host || "127.0.0.1:#{port}"}\r\n\r\n")
    raw = recv_all(s, "")
    [head, body] = String.split(raw, "\r\n\r\n", parts: 2)
    [_, status | _] = String.split(head, " ", parts: 3)
    {String.to_integer(status), head, body}
  end

  defp recv_all(s, acc) do
    case :gen_tcp.recv(s, 0, 10_000) do
      {:ok, d} -> recv_all(s, acc <> d)
      {:error, :closed} -> acc
    end
  end

  test "the page is served at the front and for each epic, and the dashboard records its URL", %{port: port} do
    for path <- ["/", "/e/e1"] do
      assert {200, head, page} = request(port, "GET", path)
      assert head =~ "text/html" and head =~ "x-frame-options: DENY"
      assert page =~ "<title>epic_loop</title>"
    end

    # Epics.dashboard/0 also wants the pid to be an epic_loop process, which the test VM is not.
    assert %{"url" => url, "pid" => pid} = Path.join(Epics.root(), "dashboard.json") |> File.read!() |> JSON.decode!()
    assert url == "http://127.0.0.1:#{port}/" and pid == System.pid()
  end

  test "the front page lists every registered epic", %{port: port} do
    assert {200, _, body} = request(port, "GET", "/api/epics")
    assert %{"now" => _, "registry" => registry, "epics" => [e]} = JSON.decode!(body)
    assert registry =~ "state/epic_loop/epics"
    assert %{"epic_id" => "e1", "title" => "The epic", "run" => %{"state" => "stopped"}, "counts" => %{"ready" => 1, "total" => 1}} = e
  end

  test "one epic's state and tickets are served, and an unregistered epic is not", %{port: port} do
    assert {200, head, body} = request(port, "GET", "/api/state?epic=e1")
    assert head =~ "application/json"
    state = JSON.decode!(body)
    assert state["epic_id"] == "e1" and state["epic"]["title"] == "The epic"
    assert [%{"id" => "e1.1", "state" => "ready"}] = state["tickets"]
    assert state["run"]["state"] == "stopped" and state["processes"] == nil
    assert state["run"]["url"] == "http://127.0.0.1:#{port}/e/e1"

    assert {404, _, body} = request(port, "GET", "/api/state?epic=other")
    assert body =~ "epic other is not registered"
    assert {200, _, body} = request(port, "GET", "/api/ticket?epic=e1&id=e1.1")
    assert %{"id" => "e1.1", "worktree" => nil} = JSON.decode!(body)
    assert {404, _, body} = request(port, "GET", "/api/ticket?epic=e1&id=other.1")
    assert body =~ "no ticket other.1"
  end

  test "only the loopback host is answered, only GET, only known paths", %{port: port} do
    assert {403, _, _} = request(port, "GET", "/api/epics", "evil.example:#{port}")
    assert {200, _, _} = request(port, "GET", "/", "localhost:#{port}")
    assert {405, _, _} = request(port, "POST", "/api/epics")
    assert {404, _, _} = request(port, "GET", "/nope")
  end

  test "a taken port falls back to a free one", %{port: port} do
    stop_supervised!(Dashboard)
    {:ok, holder} = :gen_tcp.listen(port, ip: {127, 0, 0, 1})
    pid = start_supervised!({Dashboard, port: port})
    other = :sys.get_state(pid).url |> URI.parse() |> Map.fetch!(:port)
    assert other != port and other > 0
    :gen_tcp.close(holder)
  end
end
