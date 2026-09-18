defmodule ImagePipeFiddle.MixProject do
  use Mix.Project

  def project do
    [
      app: :image_pipe_fiddle,
      version: "0.1.0",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ImagePipeFiddle.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:image_pipe, path: ".."},
      {:image_vision, "~> 0.4"},
      {:ortex, "~> 0.1"},
      {:phoenix, "~> 1.8.7"},
      {:phoenix_vite, "~> 0.6"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.3"},
      {:bandit, "~> 1.5"},
      # OpenTelemetry SDK (host-side): the library declares :opentelemetry_api
      # optional and ships the exporter; the fiddle brings the SDK to send traces
      # to a local Jaeger (see docker-compose.yml). List the exporter before
      # :opentelemetry so the OTLP exporter app starts before the SDK processor.
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry, "~> 1.7"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "assets.setup"],
      "assets.setup": ["cmd pnpm install"],
      "assets.build": ["cmd pnpm -C assets run build"],
      "assets.deploy": ["assets.build"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
