defmodule EpicLoop.Session do
  @moduledoc """
  Starting a Claude session in a herdr pane, shared by the workers and the integration session:
  record folder trust the way Claude does, wait for the pane's shell, answer the trust dialog if it
  shows anyway, and make sure the session ends up with the requested name.
  """
  alias EpicLoop.{Herdr, Log}

  @trust_re ~r/trust|Yes, proceed|Enter to continue|press enter/i
  @name_max 32

  @doc """
  A herdr agent name for `id` under `prefix`. herdr requires `[a-z][a-z0-9_-]{0,31}`, unique among
  live agents. When the whole id does not fit, the name keeps the tail of the id, which is the part
  that tells the tickets of one epic apart, and carries a short hash of the whole id so that two
  long ids never share a name.
  """
  def name(prefix, id) do
    slug = id |> String.downcase() |> String.replace(~r/[^a-z0-9_-]/, "-")
    full = prefix <> slug

    if String.length(full) <= @name_max do
      full
    else
      hash = :crypto.hash(:sha256, id) |> Base.encode16(case: :lower) |> String.slice(0, 6)
      keep = @name_max - String.length(prefix) - String.length(hash) - 1
      prefix <> hash <> "-" <> String.trim_leading(String.slice(slug, -keep, keep), "-")
    end
  end

  @doc """
  End the Claude session named `name` so its pane is back at the shell and the name is free:
  Escape cancels the running turn, the agent is awaited at idle, `/exit` closes Claude, and the name
  must then leave herdr's live agent list. ctrl+c does not do this: it cancels a command and leaves
  Claude running under the same name. :ok, or {:error, reason}.
  """
  def stop(name, timeout_ms \\ 30_000) do
    if live?(name) do
      Herdr.agent_send_keys(name, ["esc"])
      Herdr.agent_wait(name, until: "idle", timeout: timeout_ms)
      Herdr.agent_prompt(name, "/exit")
      if gone_within?(name, timeout_ms), do: :ok, else: {:error, "#{name} is still live after /exit"}
    else
      :ok
    end
  end

  defp live?(name), do: Enum.any?(Herdr.agent_list(), &(&1["name"] == name))

  defp gone_within?(name, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.cycle([nil]), false, fn _, _ ->
      cond do
        not live?(name) -> {:halt, true}
        System.monotonic_time(:millisecond) >= deadline -> {:halt, false}
        true -> Process.sleep(500); {:cont, false}
      end
    end)
  end

  @doc "Claude Code asks whether to trust a new folder; record the trust the way Claude does."
  def pre_trust(path) do
    f = Path.join(System.user_home!(), ".claude.json")

    with {:ok, raw} <- File.read(f), {:ok, d} <- JSON.decode(raw) do
      projects = d["projects"] || %{}

      unless get_in(projects, [path, "hasTrustDialogAccepted"]) do
        d = Map.put(d, "projects", Map.put(projects, path, Map.put(projects[path] || %{}, "hasTrustDialogAccepted", true)))
        tmp = f <> ".epic-loop.tmp"
        File.write!(tmp, JSON.encode!(d))
        File.rename!(tmp, f)
        Log.info("trust", "recorded trust for #{path}")
      end
    else
      _ -> Log.info("trust", "could not pre-trust #{path}")
    end
  end

  @doc "Start `claude` named `name` in `pane` with `args`. :ok, or {:error, reason}."
  def start(name, pane, args, timeout_ms) do
    case start_when_pane_ready(name, pane, args, timeout_ms) do
      :ok ->
        :ok

      {:error, e} ->
        Log.info(name, "agent start: #{e}; checking the pane for a dialog")

        if Regex.match?(@trust_re, Herdr.pane_read(pane, 40)) do
          Log.info(pane, "trust dialog in pane; selecting Yes")
          Herdr.pane_send_keys(pane, ["down", "enter"])
          # Claude now runs unnamed in the pane; wait until herdr sees it, then name it.
          Enum.reduce_while(1..12, {:error, e}, fn _, acc ->
            Process.sleep(2_500)

            case Herdr.agent_get(pane) do
              {:ok, _} -> {:halt, if(Herdr.agent_rename(pane, name), do: :ok, else: acc)}
              _ -> {:cont, acc}
            end
          end)
        else
          {:error, e}
        end
    end
  end

  # A freshly created pane's shell may still be initializing; herdr reports agent_pane_busy until it
  # reaches its prompt. Wait for it, bounded by the start timeout.
  defp start_when_pane_ready(name, pane, args, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    Enum.reduce_while(Stream.cycle([nil]), nil, fn _, _ ->
      case Herdr.agent_start(name, pane, args, timeout_ms) do
        {:error, "agent_pane_busy"} = busy ->
          if System.monotonic_time(:millisecond) < deadline, do: (Process.sleep(2_000); {:cont, nil}), else: {:halt, busy}

        other ->
          {:halt, other}
      end
    end)
  end
end
