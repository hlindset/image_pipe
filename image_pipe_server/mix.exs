defmodule ImagePipeServer.MixProject do
  use Mix.Project

  # Shares major.minor with image_pipe and image_pipe_url; patch releases are
  # independent. Released images build against this image_pipe version from Hex.
  @version "0.1.0"
  @image_pipe_version "0.1.0"

  def project do
    [
      app: :image_pipe_server,
      version: @version,
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

  # `dev/` holds the configuration reference generator, kept out of releases.
  defp elixirc_paths(:test), do: ["lib", "dev", "test/support"]
  defp elixirc_paths(:dev), do: ["lib", "dev"]
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      image_pipe_dep(),
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.18"},
      {:toml, "~> 0.7.0"},
      # OpenTelemetry SDK for OTEL_* trace export; the exporter app is listed
      # first so it starts before the SDK's span processor.
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry, "~> 1.7"}
    ] ++ vision_deps()
  end

  # Development and CI use the sibling project. Release images build with
  # IMAGE_PIPE_LIBS=hex, so they only contain library code published on Hex.
  defp image_pipe_dep do
    if System.get_env("IMAGE_PIPE_LIBS") == "hex",
      do: {:image_pipe, "== #{@image_pipe_version}"},
      else: {:image_pipe, path: "../image_pipe"}
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
