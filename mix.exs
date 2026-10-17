defmodule EpicLoop.MixProject do
  use Mix.Project

  def project do
    [
      app: :epic_loop,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: false,
      escript: [main_module: EpicLoop.CLI],
      deps: []
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]
end
