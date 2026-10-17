defmodule EpicLoop.Herdr do
  @moduledoc "herdr CLI wrappers. Responses are JSON on stdout; errors are JSON on stderr with exit 1."
  alias EpicLoop.Sh

  defp herdr(args, opts \\ []) do
    r = Sh.run("herdr", args, timeout: Keyword.get(opts, :timeout, 120_000))
    %{code: r.code, json: Sh.decode(r.out), error: parse_err(r.err), raw: r.out}
  end

  defp parse_err(e) do
    case String.trim(e) do
      "" -> nil
      t -> Sh.decode(t) || %{"message" => t}
    end
  end

  def err_code(%{error: nil, code: code}), do: "exit #{code}"
  def err_code(%{error: e, code: code}), do: get_in(e, ["error", "code"]) || e["code"] || e["message"] || "exit #{code}"

  @doc "Depth-first search for the first scalar under any of the given keys."
  def find_key(obj, keys, depth \\ 0)
  def find_key(_, _, depth) when depth > 8, do: nil

  def find_key(obj, keys, depth) when is_map(obj) do
    case Enum.find_value(keys, fn k -> v = obj[k]; if v != nil and not is_map(v) and not is_list(v), do: v end) do
      nil -> Enum.find_value(Map.values(obj), fn v -> find_key(v, keys, depth + 1) end)
      v -> v
    end
  end

  def find_key(obj, keys, depth) when is_list(obj), do: Enum.find_value(obj, fn v -> find_key(v, keys, depth + 1) end)
  def find_key(_, _, _), do: nil

  defp status_of(json), do: find_key(json, ["agent_status", "status", "state"])

  defp created(res) do
    %{
      workspace_id: get_in(res, ["workspace", "workspace_id"]),
      pane_id: get_in(res, ["root_pane", "pane_id"]),
      path: get_in(res, ["worktree", "path"])
    }
  end

  @doc "No --path: herdr chooses the location; the caller reads it back."
  def worktree_create(repo, branch, base, label) do
    r = herdr(["worktree", "create", "--cwd", repo, "--branch", branch, "--base", base, "--label", label, "--no-focus"])
    if r.code == 0, do: {:ok, created(r.json["result"])}, else: {:error, err_code(r)}
  end

  def worktree_open(repo, path) do
    r = herdr(["worktree", "open", "--cwd", repo, "--path", path, "--no-focus"])
    if r.code == 0, do: {:ok, created(r.json["result"]) |> Map.update!(:path, &(&1 || path))}, else: {:error, err_code(r)}
  end

  def worktree_list(repo), do: get_in(herdr(["worktree", "list", "--cwd", repo]).json, ["result", "worktrees"]) || []

  def worktree_remove(ws, force \\ true) do
    r = herdr(["worktree", "remove", "--workspace", ws] ++ if(force, do: ["--force"], else: []))
    r.code == 0
  end

  @doc "A worktree herdr already has open: its workspace and first pane."
  def find_worktree_pane(repo, path) do
    with %{"open_workspace_id" => ws} when is_binary(ws) <- Enum.find(worktree_list(repo), &(&1["path"] == path)),
         panes when panes != [] <- get_in(herdr(["pane", "list", "--workspace", ws]).json, ["result", "panes"]) || [] do
      {:ok, %{workspace_id: ws, pane_id: hd(panes)["pane_id"], path: path}}
    else
      _ -> nil
    end
  end

  def agent_start(name, pane, args, timeout) do
    r = herdr(["agent", "start", name, "--kind", "claude", "--pane", pane, "--timeout", Integer.to_string(timeout), "--" | args], timeout: timeout + 15_000)
    if r.code == 0, do: :ok, else: {:error, err_code(r)}
  end

  def agent_get(name) do
    r = herdr(["agent", "get", name])
    if r.code == 0, do: {:ok, status_of(r.json) || "unknown"}, else: {:error, err_code(r)}
  end

  @doc "The agent's herdr record (`agent_status`, `focused`, `pane_id`, ...): {:ok, map} or {:error, code}."
  def agent_info(name) do
    r = herdr(["agent", "get", name])
    if r.code == 0, do: {:ok, get_in(r.json, ["result", "agent"]) || %{}}, else: {:error, err_code(r)}
  end

  def agent_prompt(name, text, opts \\ []) do
    args = ["agent", "prompt", name, text] ++ if(opts[:wait], do: ["--wait"], else: []) ++ if(opts[:timeout], do: ["--timeout", Integer.to_string(opts[:timeout])], else: [])
    r = herdr(args, timeout: (opts[:timeout] || 60_000) + 15_000)
    if r.code == 0, do: {:ok, status_of(r.json)}, else: {:error, err_code(r)}
  end

  def agent_wait(name, opts \\ []) do
    args = ["agent", "wait", name] ++ if(opts[:until], do: ["--until", opts[:until]], else: []) ++ if(opts[:timeout], do: ["--timeout", Integer.to_string(opts[:timeout])], else: [])
    r = herdr(args, timeout: (opts[:timeout] || 60_000) + 15_000)
    if r.code == 0, do: {:ok, status_of(r.json)}, else: {:error, err_code(r)}
  end

  @doc """
  The agent's recent terminal text: {:ok, text} or {:error, code}. herdr can scroll back only while
  the agent is idle; while it works, Claude's alternate screen allows only the visible snapshot, so
  an agent_not_idle refusal is retried with `--source visible`.
  """
  def agent_read(name, lines \\ 80) do
    case read_source(name, lines, "recent-unwrapped") do
      {:error, "agent_not_idle"} -> read_source(name, lines, "visible")
      other -> other
    end
  end

  defp read_source(name, lines, source) do
    r = herdr(["agent", "read", name, "--source", source, "--lines", Integer.to_string(lines), "--format", "text"])
    if r.code == 0, do: {:ok, text_of(r)}, else: {:error, err_code(r)}
  end

  def pane_read(pane, lines \\ 80) do
    r = herdr(["pane", "read", pane, "--source", "recent-unwrapped", "--lines", Integer.to_string(lines), "--format", "text"])
    text_of(r)
  end

  defp text_of(r) do
    case find_key(r.json, ["text", "content", "output"]) do
      t when is_binary(t) -> t
      _ ->
        case get_in(r.json, ["result", "lines"]) || get_in(r.json, ["result", "rows"]) do
          l when is_list(l) -> Enum.join(l, "\n")
          _ -> r.raw
        end
    end
  end

  def notification_show(title, body, sound \\ "request"), do: herdr(["notification", "show", title, "--body", body, "--sound", sound]).code == 0
  def agent_send_keys(name, keys), do: herdr(["agent", "send-keys", name | keys]).code == 0
  def pane_send_keys(pane, keys), do: herdr(["pane", "send-keys", pane | keys]).code == 0
  def agent_rename(target, name), do: herdr(["agent", "rename", target, name]).code == 0
  def agent_list, do: get_in(herdr(["agent", "list"]).json, ["result", "agents"]) || []
end
