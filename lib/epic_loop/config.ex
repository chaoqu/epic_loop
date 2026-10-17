defmodule EpicLoop.Config do
  @moduledoc """
  The per-repo config file. Relative rules-file paths resolve against the
  directory that holds the config file; `~` expands in `repo`.
  """

  def load(path) do
    path = Path.expand(path)
    base = Path.dirname(path)
    c = path |> File.read!() |> JSON.decode!()

    c
    |> Map.update!("repo", &expand/1)
    |> resolve(["worker", "rulesFile"], base)
    |> resolve(["review", "rulesFile"], base)
    |> resolve(["integratedReview", "rulesFile"], base)
    |> Map.put("configPath", path)
  end

  def get(c, keys, default \\ nil) do
    case get_in(c, keys) do
      nil -> default
      v -> v
    end
  end

  defp resolve(c, keys, base) do
    case get_in(c, keys) do
      nil -> c
      p -> put_in(c, keys, Path.expand(p, base))
    end
  end

  defp expand("~" <> rest), do: Path.join(System.user_home!(), rest)
  defp expand(p), do: Path.expand(p)
end
