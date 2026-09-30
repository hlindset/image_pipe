defmodule ImagePipeServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_pipe_server,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
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

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:image_pipe, path: "../image_pipe"},
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.18"},
      {:toml, "~> 0.7.0"}
    ] ++ vision_deps()
  end

  # The -vision image builds with IMAGE_VISION=1 to bundle the default
  # detector: `image_vision` with its ONNX backend `ortex` (a Rust NIF).
  defp vision_deps do
    if System.get_env("IMAGE_VISION") in ["1", "true"],
      do: [{:image_vision, "~> 0.4"}, {:ortex, "~> 0.1"}],
      else: []
  end

  defp releases do
    [
      image_pipe_server: [
        include_executables_for: [:unix]
      ]
    ]
  end
end
