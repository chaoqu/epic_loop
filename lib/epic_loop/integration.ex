defmodule EpicLoop.Integration do
  @moduledoc """
  The integration branch, its worktree and the interactive session in it. `epic_loop init` creates
  them; `epic_loop run` adopts them and refuses to start without them. The worktree is where the epic
  is set up by hand (dev server, data), planned into tickets, and merged into; the loop never creates
  it on its own, so a missing worktree is an error rather than a silent side effect.
  """
  alias EpicLoop.{Artifact, Git, Herdr, Log, Session, Sh}

  def branch(cfg, epic), do: "#{get_in(cfg, ["integration", "branchPrefix"]) || "epic/"}#{epic}"

  def session_name(epic), do: Session.name("epic-", epic)

  @doc "The integration worktree herdr knows for the epic branch, or nil."
  def find(cfg, epic_branch) do
    case Enum.find(Herdr.worktree_list(cfg["repo"]), &(&1["is_linked_worktree"] and &1["branch"] == epic_branch)) do
      %{"path" => path} = w -> %{path: path, workspace_id: w["open_workspace_id"], branch: epic_branch}
      nil -> nil
    end
  end

  @doc """
  The branch with its marker commit, and the worktree: created when missing, otherwise used as is.
  `integration.worktreeSetup` runs once, in a worktree this call created.
  """
  def ensure(cfg, epic) do
    epic_branch = branch(cfg, epic)
    %{created: branch_created, marker: marker} = Git.ensure_epic_branch(cfg["repo"], epic_branch, cfg["baseBranch"])
    Log.info("init", "#{if branch_created, do: "created", else: "using"} #{epic_branch}; marker #{String.slice(marker, 0, 8)}")

    case find(cfg, epic_branch) do
      %{path: path} = w ->
        Log.info("init", "using integration worktree #{path}")
        Map.merge(w, %{marker: marker, created: false, ignored: Artifact.warn_unless_ignored(path, "init")})

      nil ->
        case Herdr.worktree_create(cfg["repo"], epic_branch, epic_branch, epic_branch) do
          {:ok, c} ->
            Log.info("init", "herdr created integration worktree at #{c.path}")

            Enum.each(get_in(cfg, ["integration", "worktreeSetup"]) || [], fn cmd ->
              r = Sh.sh(cmd, cwd: c.path, timeout: cfg["checkTimeoutMs"] || 600_000)
              Log.info("init", "integration.worktreeSetup: #{cmd} -> exit #{r.code}")
            end)

            %{path: c.path, workspace_id: c.workspace_id, branch: epic_branch, marker: marker, created: true, ignored: Artifact.warn_unless_ignored(c.path, "init")}

          {:error, e} ->
            raise("cannot create the integration worktree for #{epic_branch}: #{e}")
        end
    end
  end

  @doc "The worktree's pane, opening its workspace when herdr has it closed."
  def pane(cfg, wt) do
    case Herdr.find_worktree_pane(cfg["repo"], wt.path) || Herdr.worktree_open(cfg["repo"], wt.path) do
      {:ok, c} -> {:ok, c.pane_id}
      {:error, e} -> {:error, "herdr cannot open #{wt.path}: #{e}"}
    end
  end

  @doc """
  The interactive Claude session in the worktree's pane: started with `integration.model` and
  `integration.claudeArgs`, unless the pane already runs an agent, which is then reported as is.
  """
  def start_session(cfg, epic, wt) do
    name = session_name(epic)

    with {:ok, pane} <- pane(cfg, wt) do
      case Herdr.agent_get(pane) do
        {:ok, status} ->
          {:ok, %{pane_id: pane, name: name, started: false, status: status}}

        {:error, _} ->
          Session.pre_trust(wt.path)
          model = case get_in(cfg, ["integration", "model"]), do: (nil -> []; m -> ["--model", m])
          args = model ++ (get_in(cfg, ["integration", "claudeArgs"]) || [])
          timeout = get_in(cfg, ["worker", "agentStartTimeoutMs"]) || 90_000

          case Session.start(name, pane, args, timeout) do
            :ok -> {:ok, %{pane_id: pane, name: name, started: true, status: "starting"}}
            {:error, e} -> {:error, "could not start the integration session in #{pane}: #{e}"}
          end
      end
    end
  end
end
