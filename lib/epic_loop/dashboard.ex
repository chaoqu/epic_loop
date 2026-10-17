defmodule EpicLoop.Dashboard do
  @moduledoc """
  One web page for every epic: `epic_loop dashboard` serves it on 127.0.0.1, with nothing beyond OTP.
  The epics are the ones commands registered (see `EpicLoop.Epics`). For each, the page reads br, herdr,
  git and the loop's files, and the live state the epic's run writes to `board.json` every second (see
  `EpicLoop.BoardFile`). A run never talks to the dashboard, so a loop runs the same with or without one,
  and a dashboard started at any time sees every run.

  - `GET /` lists the epics and `GET /e/<epic>` is one epic: the same page, compiled in from
    `dashboard.html`, which picks its view from the path.
  - `GET /api/epics` is one summary per epic (`EpicLoop.Snapshot.summary/1`), newest registered first.
  - `GET /api/state?epic=<id>` is `EpicLoop.Snapshot.view/3`.
  - `GET /api/ticket?epic=<id>&id=<ticket>` adds one ticket's brief, commits, diffstat, reports, agent
    screen and timing record.

  It only reads; answering and stopping stay with `epic_loop answer` and `epic_loop stop`, whose command
  lines the page shows. Each epic's external half is collected in a separate process, cached, and
  refreshed only while a page asks for it and at most every four seconds, so an open tab costs a few
  dozen short commands every few seconds and a closed one nothing. Each ticket's transcripts are read
  a little at a time: the dashboard keeps where it stopped in each (see `EpicLoop.Usage`). Where the run stands (its `board.json`,
  the lock's holder, the stop file) is read on every request.
  Requests are one per connection, parsed by the VM's HTTP packet mode. Only requests whose Host names
  the loopback address are answered, so a web page cannot read the dashboard through DNS rebinding.
  """
  use GenServer
  alias EpicLoop.{Board, Config, Epics, Log, Snapshot, State}

  @external_resource Path.join(__DIR__, "dashboard.html")
  @page File.read!(Path.join(__DIR__, "dashboard.html"))
  @fresh_ms 4_000

  def default_port, do: 4040

  @doc "Options: `port` (0 picks a free one; a taken port falls back to a free one)."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case listen(opts[:port] || default_port()) do
      {:ok, sock, port} ->
        url = "http://127.0.0.1:#{port}/"
        EpicLoop.Usage.table()
        me = self()
        spawn_link(fn -> accept(sock, %{server: me, port: port, url: url}) end)
        Epics.put_dashboard(url)
        Log.info("dashboard", url)
        {:ok, %{sock: sock, url: url, epics: %{}}}

      {:error, reason} ->
        Log.info("dashboard", "cannot listen on port #{opts[:port]}: #{inspect(reason)}")
        :ignore
    end
  end

  defp listen(port) do
    with {:ok, sock} <- listen_on(port), {:ok, actual} <- :inet.port(sock), do: {:ok, sock, actual}
  end

  defp listen_on(port) do
    opts = [:binary, packet: :http_bin, active: false, reuseaddr: true, ip: {127, 0, 0, 1}, backlog: 64]

    case :gen_tcp.listen(port, opts) do
      {:error, :eaddrinuse} when port != 0 -> :gen_tcp.listen(0, opts)
      other -> other
    end
  end

  # ---------------------------------------------------------------- the external half, cached per epic
  @impl true
  def handle_call({:external, entry}, from, s) do
    epic = entry["epic"]
    e = refresh(Map.get(s.epics, epic, %{cache: nil, collecting: nil, waiters: []}), entry)

    case e.cache do
      nil -> {:noreply, put_in(s.epics[epic], %{e | waiters: [from | e.waiters]})}
      cache -> {:reply, cache, put_in(s.epics[epic], e)}
    end
  end

  # The collector hands its result back as its exit reason, so a crash and a result arrive the same way.
  @impl true
  def handle_info({:DOWN, ref, :process, _, reason}, s) do
    case Enum.find(s.epics, fn {_, e} -> e.collecting == ref end) do
      nil ->
        {:noreply, s}

      {epic, e} ->
        cache =
          case reason do
            {:collected, c} -> c
            other -> %{ext: Snapshot.empty(["collecting the snapshot failed: #{String.slice(inspect(other), 0, 500)}"]), cfg: (e.cache || %{cfg: %{}}).cfg}
          end

        Enum.each(e.waiters, &GenServer.reply(&1, cache))
        {:noreply, put_in(s.epics[epic], %{e | cache: cache, collecting: nil, waiters: []})}
    end
  end

  def handle_info(_, s), do: {:noreply, s}

  defp refresh(%{collecting: nil} = e, entry) do
    if e.cache == nil or Board.now() - e.cache.ext.collected_at >= @fresh_ms do
      {_, ref} = spawn_monitor(fn -> exit({:collected, collect(entry)}) end)
      %{e | collecting: ref}
    else
      e
    end
  end

  defp refresh(e, _entry), do: e

  # The config is read again on every collection, so an edited config shows on the next one.
  defp collect(entry) do
    cfg = Config.load(entry["config"])
    %{ext: Snapshot.collect(entry["epic"], cfg), cfg: cfg}
  rescue
    e -> %{ext: Snapshot.empty(["cannot read the config #{entry["config"]}: #{Exception.message(e)}"]), cfg: %{"configPath" => entry["config"], "repo" => entry["repo"]}}
  end

  # ---------------------------------------------------------------- HTTP
  defp accept(sock, conn) do
    case :gen_tcp.accept(sock) do
      {:ok, c} ->
        pid =
          spawn(fn ->
            receive do
              :go -> serve(c, conn)
            after
              5_000 -> :gen_tcp.close(c)
            end
          end)

        :gen_tcp.controlling_process(c, pid)
        send(pid, :go)
        accept(sock, conn)

      {:error, :closed} ->
        :ok

      {:error, _} ->
        Process.sleep(100)
        accept(sock, conn)
    end
  end

  defp serve(c, conn) do
    with {:ok, {:http_request, method, {:abs_path, target}, _}} <- :gen_tcp.recv(c, 0, 10_000),
         {:ok, headers} <- headers(c, %{}, 0) do
      {status, type, body} =
        try do
          route(method, URI.parse(target), headers, conn)
        rescue
          e -> {500, "text/plain", "dashboard error: #{Exception.message(e)}"}
        catch
          :exit, reason -> {503, "text/plain", "dashboard busy: #{String.slice(inspect(reason), 0, 300)}"}
        end

      respond(c, status, type, body)
    end

    :gen_tcp.close(c)
  end

  defp headers(_c, _acc, n) when n > 100, do: {:error, :too_many_headers}

  defp headers(c, acc, n) do
    case :gen_tcp.recv(c, 0, 10_000) do
      {:ok, {:http_header, _, name, _, value}} -> headers(c, Map.put(acc, name |> to_string() |> String.downcase(), value), n + 1)
      {:ok, :http_eoh} -> {:ok, acc}
      other -> {:error, other}
    end
  end

  @doc "Whether a request's Host header names this dashboard on the loopback address."
  def host_ok?(host, port), do: host in ["127.0.0.1:#{port}", "localhost:#{port}"]

  defp route(method, uri, headers, conn) do
    q = URI.decode_query(uri.query || "")

    cond do
      not host_ok?(headers["host"], conn.port) -> {403, "text/plain", "this dashboard answers on 127.0.0.1:#{conn.port} only"}
      method != :GET -> {405, "text/plain", "read-only"}
      uri.path == "/" or String.starts_with?(uri.path, "/e/") -> {200, "text/html; charset=utf-8", @page}
      uri.path == "/api/epics" -> json(epics(conn))
      uri.path == "/api/state" -> with_epic(q["epic"], &json(state(&1, conn)))
      uri.path == "/api/ticket" -> with_epic(q["epic"], &ticket(&1, q["id"], conn))
      true -> {404, "text/plain", "not found"}
    end
  end

  defp with_epic(epic, fun) do
    case is_binary(epic) && Epics.get(epic) do
      %{} = entry -> fun.(entry)
      _ -> {404, "text/plain", "epic #{epic} is not registered; any epic_loop command naming it with --epic and --config registers it"}
    end
  end

  defp epics(conn) do
    list =
      Epics.list()
      |> Task.async_stream(&Snapshot.summary(state(&1, conn)), timeout: 70_000, on_timeout: :kill_task, max_concurrency: 8)
      |> Enum.flat_map(fn {:ok, s} -> [s]; _ -> [] end)

    %{now: Board.now(), registry: Path.join(Epics.root(), "epics"), epics: list}
  end

  # Where the run stands is read fresh on every request: its board, the lock's holder and the stop file.
  # Only the rest comes from the cache. The integration worktree herdr reports wins over the one the
  # registry recorded.
  defp state(entry, conn) do
    %{ext: ext, cfg: cfg} = GenServer.call(conn.server, {:external, entry}, 60_000)
    int = Enum.find(ext.worktrees, &(&1.role == "integration"))
    path = (int && int.path) || entry["integration"]
    ext = if path && File.dir?(path), do: %{ext | files: Map.merge(ext.files, %{holder: State.holder(path), stop_requested: File.exists?(State.stop_file(path))})}, else: ext
    Snapshot.view(ext, Snapshot.read_board(path), %{epic: entry["epic"], cfg: cfg, url: conn.url <> "e/" <> URI.encode(entry["epic"])})
  end

  defp ticket(entry, id, conn) do
    %{ext: ext} = GenServer.call(conn.server, {:external, entry}, 60_000)

    if Enum.any?(ext.issues, &(&1["id"] == id)),
      do: json(Snapshot.ticket_detail(ext, id)),
      else: {404, "text/plain", "no ticket #{id} in epic #{entry["epic"]}"}
  end

  defp json(term), do: {200, "application/json", JSON.encode!(Snapshot.jsonable(term))}

  defp respond(c, status, type, body) do
    reason = %{200 => "OK", 403 => "Forbidden", 404 => "Not Found", 405 => "Method Not Allowed", 500 => "Internal Server Error", 503 => "Service Unavailable"}[status]

    :gen_tcp.send(c, [
      "HTTP/1.1 #{status} #{reason}\r\n",
      "content-type: #{type}\r\ncontent-length: #{IO.iodata_length(body)}\r\ncache-control: no-store\r\nconnection: close\r\n",
      "x-content-type-options: nosniff\r\nx-frame-options: DENY\r\n",
      "content-security-policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; img-src data:\r\n\r\n",
      body
    ])
  end
end
