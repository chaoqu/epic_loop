defmodule EpicLoop.Log do
  @moduledoc "Timestamped lines to stdout and to the epic's loop.log."

  def open(path) do
    File.mkdir_p!(Path.dirname(path))
    :persistent_term.put({__MODULE__, :file}, path)
  end

  def info(scope, msg, extra \\ nil) do
    suffix = if extra == nil, do: "", else: " " <> JSON.encode!(extra)
    line = "#{DateTime.utc_now() |> DateTime.to_iso8601()} [#{scope}] #{msg}#{suffix}"
    IO.puts(line)

    case :persistent_term.get({__MODULE__, :file}, nil) do
      nil -> :ok
      f -> File.write(f, line <> "\n", [:append])
    end
  end
end
