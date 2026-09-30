defmodule ImagePipeServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_pipe_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
    ]
  end

  def application do
    [
      mod: {ImagePipeServer.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:image_pipe, path: "../image_pipe"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.18"}
    ]
  end

  defp releases do
    [
      image_pipe_server: [
        include_executables_for: [:unix]
      ]
    ]
  end
end
