defmodule EpicLoop.Attention do
  @moduledoc """
  Getting `attention.md` to the person. Workers, the coordinator and `epic_loop answer` append entries
  with `State.attention/3` and `State.answered/5`; the coordinator calls `deliver/1` on every pass.

  An entry is one of three kinds, by its title:

  - a question: a ticket's `needs you` or `escalated`, which asks for an answer;
  - an answer: `<ticket> answered by …` or `answered from the plan`, a record for the attention
    history, which is neither notified nor given to anyone;
  - a notice: anything else.

  The entries the integration session has not been given go to it as a prompt. The session answers a
  question itself when it has a recommended answer, through `epic_loop answer --by session`, which
  records the answer; otherwise it shows the question to the person and waits. A notice raises a herdr
  notification at once. A question raises one only once the session leaves it to the person: the
  session ended the turn it was given the question in, or stopped on a dialog, and no answer to it
  has been recorded since. A question that has no session to go to, or that the session could not be
  given for ten minutes, is notified then.

  The session gets the prompt only while herdr reports it idle. While its pane has focus the person
  may be typing in it, so the prompt also waits until the screen has not changed for a whole pass.
  `attention.delivered` holds how many bytes of `attention.md` the session has been given: a new run
  continues from it, and a run that finds none starts at the end of the file.
  """
  alias EpicLoop.{Artifact, Herdr, Integration, Log, State}

  defstruct [:int_wt, :epic, :config_path, :session, delivered: 0, notified: 0, held: nil, last_screen: nil, pending: []]

  @paste_max 8_000
  @surface_after_ms 600_000

  def new(int_wt, epic, config_path) do
    delivered =
      with {:ok, raw} <- File.read(State.delivered_file(int_wt)), {n, ""} <- Integer.parse(String.trim(raw)) do
        n
      else
        _ -> save(int_wt, size(int_wt))
      end

    %__MODULE__{int_wt: int_wt, epic: epic, config_path: config_path, session: Integration.session_name(epic), delivered: delivered, notified: delivered}
  end

  defp size(int_wt), do: case(File.stat(State.attention_file(int_wt)), do: ({:ok, st} -> st.size; _ -> 0))
  defp save(int_wt, n), do: (Artifact.ensure_dir(int_wt); File.write!(State.delivered_file(int_wt), Integer.to_string(n)); n)

  @doc """
  Notify about new notices, give the session the entries it has not had, and notify about the
  questions it left to the person; returns the updated struct.
  """
  def deliver(a) do
    text = case File.read(State.attention_file(a.int_wt)), do: ({:ok, t} -> t; _ -> "")
    # A file shorter than the offset was replaced, so all of it is new.
    a = if a.delivered > byte_size(text), do: %{a | delivered: 0, notified: 0, pending: []}, else: a
    # Questions are surfaced before the give, so one given on this pass waits for the session's turn.
    a |> notify(text) |> surface(text) |> give(text)
  end

  @doc """
  The entries in a stretch of `attention.md`: the title of each `## <timestamp> <title>` heading, the
  body under it, and the entry as written.
  """
  def entries(chunk) do
    chunk
    |> String.split(~r/^## /m)
    |> Enum.drop(1)
    |> Enum.map(fn part ->
      [heading | rest] = String.split(part, "\n", parts: 2)
      title = case String.split(heading, " ", parts: 2), do: ([_ts, t] -> t; [t] -> t)
      %{title: String.trim(title), body: String.trim(Enum.join(rest)), raw: String.trim("## " <> part)}
    end)
  end

  @doc "An entry's kind, by its title: `:question`, `:answer` or `:notice`."
  def kind(title) do
    cond do
      Regex.match?(~r/^\S+ answered (by|from) /, title) -> :answer
      Regex.match?(~r/^\S+ (needs you|escalated)$/, title) -> :question
      true -> :notice
    end
  end

  defp ticket(title), do: title |> String.split(" ", parts: 2) |> hd()

  @doc """
  The entries of a stretch that still ask something of someone: no answers, and no question an answer
  later in the stretch has settled.
  """
  def live(es) do
    es
    |> Enum.with_index(1)
    |> Enum.reject(fn {e, i} ->
      kind(e.title) == :answer or (kind(e.title) == :question and answers?(Enum.drop(es, i), ticket(e.title)))
    end)
    |> Enum.map(&elem(&1, 0))
  end

  defp answers?(es, t), do: Enum.any?(es, &(kind(&1.title) == :answer and ticket(&1.title) == t))

  defp tail(text, from), do: binary_part(text, from, byte_size(text) - from)

  # Notices are notified now; questions wait in `pending` for the session's turn.
  defp notify(a, text) when a.notified >= byte_size(text), do: a

  defp notify(a, text) do
    {questions, notices} = entries(tail(text, a.notified)) |> live() |> Enum.split_with(&(kind(&1.title) == :question))
    show(notices)
    from = byte_size(text)
    pending = for e <- questions, do: %{entry: e, ticket: ticket(e.title), from: from, since: now(), given: false}
    %{a | notified: from, pending: a.pending ++ pending}
  end

  # A pending question goes to the person once the session has left it to them, there is no session,
  # or the session could not be given it in time. One answered since it was written is dropped.
  defp surface(a, text) do
    case Enum.reject(a.pending, fn p -> answers?(entries(tail(text, p.from)), p.ticket) end) do
      [] -> %{a | pending: []}
      open -> surface_open(a, open)
    end
  end

  defp surface_open(a, open) do
    status = case Herdr.agent_info(a.session), do: ({:ok, %{"agent_status" => st}} -> st; _ -> :none)

    {due, later} =
      Enum.split_with(open, fn p ->
        status == :none or (p.given and status in ["idle", "done", "blocked"]) or now() - p.since >= @surface_after_ms
      end)

    if due != [] do
      show(Enum.map(due, & &1.entry))
      Log.info("attention", "left to the person: #{Enum.map_join(due, "; ", & &1.entry.title)}")
    end

    %{a | pending: later}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp show([]), do: :ok
  defp show([e]), do: Herdr.notification_show("epic_loop: #{e.title}", String.slice(first_line(e.body), 0, 200))
  defp show(es), do: Herdr.notification_show("epic_loop: #{length(es)} new entries", String.slice(Enum.map_join(es, "; ", & &1.title), 0, 200))

  defp first_line(body), do: body |> String.split("\n", parts: 2) |> hd()

  defp give(a, text) when a.delivered >= byte_size(text), do: %{a | held: nil, last_screen: nil}

  defp give(a, text) do
    case live(entries(tail(text, a.delivered))) do
      [] ->
        %{a | delivered: save(a.int_wt, byte_size(text)), held: nil, last_screen: nil}

      es ->
        case ready(a) do
          {:ok, a} ->
            case Herdr.agent_prompt(a.session, prompt_text(a, es)) do
              {:ok, _} ->
                Log.info("attention", "gave #{count(es)} to #{a.session}")
                %{a | delivered: save(a.int_wt, byte_size(text)), held: nil, last_screen: nil, pending: Enum.map(a.pending, &%{&1 | given: true})}

              {:error, e} ->
                hold(a, es, "prompt failed: #{e}")
            end

          {:hold, reason, a} ->
            hold(a, es, reason)
        end
    end
  end

  defp ready(a) do
    case Herdr.agent_info(a.session) do
      {:error, e} ->
        {:hold, "no session named #{a.session} (#{e})", a}

      {:ok, %{"agent_status" => st}} when st not in ["idle", "done"] ->
        {:hold, "the session is #{st}", %{a | last_screen: nil}}

      {:ok, %{"focused" => true}} ->
        screen = case Herdr.agent_read(a.session, 20), do: ({:ok, t} -> t; _ -> nil)
        if screen != nil and screen == a.last_screen, do: {:ok, a}, else: {:hold, "the session has focus and its screen changed since the last pass", %{a | last_screen: screen}}

      {:ok, _} ->
        {:ok, a}
    end
  end

  # Logged when the reason changes, not on every pass.
  defp hold(a, es, reason) do
    if reason != a.held, do: Log.info("attention", "holding #{count(es)} for #{a.session}: #{reason}")
    %{a | held: reason}
  end

  defp count([_]), do: "1 entry"
  defp count(es), do: "#{length(es)} entries"

  defp prompt_text(a, es) do
    file = State.attention_file(a.int_wt)
    pasted = Enum.map_join(es, "\n\n", & &1.raw)

    body =
      if byte_size(pasted) <= @paste_max,
        do: pasted,
        else: "They are too long to paste here; read them at the end of #{file}:\n" <> Enum.map_join(es, "\n", &"- #{&1.title}")

    answer = "epic_loop answer --epic #{a.epic} --config #{a.config_path} --ticket <ticket-id>"

    """
    epic_loop has #{count(es)} from #{file} for the person running epic #{a.epic}.

    A "needs you" or "escalated" entry asks for an answer. Decide first whether you have a recommended answer.
    - If you do, send it yourself without waiting for the person, then tell them in a few sentences what you answered and why:
        #{answer} --by session --why "<why, in one sentence>" --text "<the answer>"
    - If you do not, show the entry to the person exactly as written, add your analysis, and wait for their reply. You have none when the epic, the ticket and the code leave the choice to the person (product behaviour no spec describes, scope, cost, anything irreversible or touching production), or when only the person can act, such as a dialog in a worker's pane, which you never answer yourself. Pass their answer on with:
        #{answer} --by person --text "<their answer>"
    Either command records the answer in the epic's attention history. Show every other entry to the person exactly as written.

    #{body}
    """
  end
end
