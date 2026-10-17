defmodule EpicLoop.Sh do
  @moduledoc """
  Child processes with a hard timeout. Every external tool (br, herdr, git, claude) goes through
  here. The command runs under `sh -c 'exec "$@"'` so the OS pid we kill on timeout is the tool
  itself; stderr is captured to a temp file because ports only carry stdout.
  """

  @type result :: %{code: integer, out: binary, err: binary}

  @spec run(binary, [binary], keyword) :: result
  def run(cmd, args, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 120_000)
    input = Keyword.get(opts, :input)
    err_file = tmp("err")
    in_file = if input, do: tmp("in")
    if in_file, do: File.write!(in_file, input)

    script = if in_file, do: ~s(exec "$@" <"$EL_IN" 2>"$EL_ERR"), else: ~s(exec "$@" 2>"$EL_ERR")

    env =
      [{"EL_ERR", err_file}] ++
        if(in_file, do: [{"EL_IN", in_file}], else: []) ++ Keyword.get(opts, :env, [])

    port_opts =
      [
        :binary,
        :exit_status,
        :hide,
        args: ["-c", script, "sh", cmd | args],
        env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
      ] ++ if(opts[:cwd], do: [cd: to_charlist(opts[:cwd])], else: [])

    port = Port.open({:spawn_executable, ~c"/bin/sh"}, port_opts)
    deadline = System.monotonic_time(:millisecond) + timeout
    key = track(port, cmd, args, opts)

    result =
      try do
        collect(port, "", deadline)
      after
        EpicLoop.Board.delete(key)
      end

    err = case File.read(err_file), do: ({:ok, e} -> e; _ -> "")
    File.rm(err_file)
    if in_file, do: File.rm(in_file)

    case result do
      {:ok, code, out} -> %{code: code, out: out, err: err}
      {:timeout, out} -> %{code: -1, out: out, err: err <> "\n[timeout after #{timeout}ms]"}
    end
  end

  @doc "Run a shell command line (acceptance checks are written as shell)."
  def sh(line, opts \\ []), do: run("/bin/sh", ["-c", line], opts)

  @doc "Run and decode stdout as JSON; `json` is nil when stdout is not JSON."
  def json(cmd, args, opts \\ []) do
    r = run(cmd, args, opts)
    Map.put(r, :json, decode(r.out))
  end

  def decode(text) do
    case JSON.decode(String.trim(text)) do
      {:ok, v} -> v
      _ -> nil
    end
  end

  # The command in flight, on the board for the dashboard: which process runs it, where, since when, and
  # its OS pid (the tool's own, since sh execs it). An optional `label` says what it is for.
  defp track(port, cmd, args, opts) do
    key = {:cmd, make_ref()}
    os_pid = case Port.info(port, :os_pid), do: ({:os_pid, p} -> p; _ -> nil)
    line = case {cmd, args}, do: ({"/bin/sh", ["-c", l]} -> l; _ -> Enum.join([cmd | args], " "))
    EpicLoop.Board.put(key, %{owner: self(), line: String.slice(line, 0, 400), label: opts[:label], cwd: opts[:cwd], os_pid: os_pid, started_at: EpicLoop.Board.now()})
    key
  end

  defp collect(port, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, d}} -> collect(port, acc <> d, deadline)
      {^port, {:exit_status, code}} -> {:ok, code, acc}
    after
      remaining ->
        kill(port)
        {:timeout, acc}
    end
  end

  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> System.cmd("kill", ["-9", Integer.to_string(pid)], stderr_to_stdout: true)
      _ -> :ok
    end

    try do
      Port.close(port)
    rescue
      _ -> :ok
    end
  end

  defp tmp(tag) do
    Path.join(System.tmp_dir!(), "epic-loop-#{tag}-#{System.unique_integer([:positive])}")
  end
end
