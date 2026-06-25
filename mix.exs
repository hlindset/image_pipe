defmodule ImagePipe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hlindset/image_pipe"

  def project do
    [
      app: :image_pipe,
      version: @version,
      description: description(),
      package: package(),
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      compilers: extra_compilers(Mix.env()) ++ Mix.compilers(),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: [
        main: "readme",
        source_ref: "v#{@version}",
        source_url: @source_url,
        assets: %{"docs/assets" => "docs/assets"},
        extras: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE.md",
          "docs/cache.md",
          "docs/operational_notes.md",
          "docs/telemetry.md",
          "docs/debug_headers.md",
          {"docs/cookbook/opentelemetry-jaeger.md", title: "OpenTelemetry → Jaeger"},
          "docs/imgproxy_path_api.md",
          "docs/imgproxy_support_matrix.md",
          "docs/iiif_3_support_matrix.md",
          "docs/transform_operations.md"
        ],
        groups_for_modules: [
          "Package API": [ImagePipe],
          "Plug API": [ImagePipe.Plug],
          "Parser API": [ImagePipe.Parser, ~r/ImagePipe\.Parser\..*/],
          "Plan Model": [ImagePipe.Plan, ~r/ImagePipe\.Plan\..*/],
          "Transform API": [ImagePipe.Transform, ~r/ImagePipe\.Transform\..*/],
          "Cache API": [ImagePipe.Cache, ~r/ImagePipe\.Cache\..*/],
          "Runtime Internals": [
            ~r/ImagePipe\.Source.*/,
            ~r/ImagePipe\.Output.*/,
            ~r/ImagePipe\.Request.*/,
            ~r/ImagePipe\.Response.*/,
            ImagePipe.Telemetry
          ]
        ]
      ],
      test_coverage: [tool: ExCoveralls]
    ]
  end

  def application do
    [
      mod: {ImagePipe.Application, []},
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "autoquality.bench": :test,
        "autoquality.corpus": :test,
        "autoquality.corpus.capture": :test,
        "imgproxy.diagnose": :test,
        "imgproxy.gen_report": :test,
        "imgproxy.reauthor": :test,
        "imgproxy.gen_sources": :test,
        "twicpics.gen_fixtures": :test,
        "twicpics.diagnose": :test,
        "twicpics.gen_report": :test,
        "twicpics.reauthor": :test,
        "worktrees.clean": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(_env), do: ["lib"]

  defp extra_compilers(:prod), do: []
  defp extra_compilers(_env), do: [:boundary]

  defp description do
    "A Plug-based image optimization server with an imgproxy-compatible path parser."
  end

  defp package do
    [
      files: [
        "lib",
        "priv",
        "docs/cache.md",
        "docs/assets/demo-fiddle-desktop.png",
        "docs/imgproxy_path_api.md",
        "docs/imgproxy_support_matrix.md",
        "docs/iiif_3_support_matrix.md",
        "docs/operational_notes.md",
        "docs/telemetry.md",
        "docs/debug_headers.md",
        "docs/cookbook/opentelemetry-jaeger.md",
        "docs/transform_operations.md",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "CHANGELOG.md"
      ],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      },
      maintainers: ["Håvard Lindset"]
    ]
  end

  defp deps do
    base = [
      {:plug, "~> 1.18"},
      {:telemetry, "~> 1.0"},
      # Opt-in OpenTelemetry export. Compile against the lightweight API only
      # (optional: true, NO `only:` — the optional edge orders a host-provided
      # opentelemetry_api before image_pipe so the compile guard activates). The
      # SDK is the host's at runtime; we pull it only for our own tests.
      {:opentelemetry_api, "~> 1.5", optional: true},
      {:opentelemetry, "~> 1.7", only: :test},
      {:nimble_options, "~> 1.1"},
      {:image, "~> 0.69"},
      {:ssimulacra2,
       github: "hlindset/ssimulacra2", ref: "c95683deefcafd7313e149d0d5e30a3328c14efd"},
      {:butteraugli,
       github: "hlindset/butteraugli", ref: "2e2e054545802f5fd6e0d39d386c0db974fdfd5b"},
      # No precompiled NIF is published for ssimulacra2's git ref, so the Rust NIF
      # is built from source. RustlerPrecompiled's force-build path needs Rustler
      # available, and `force_build: true` makes it always build locally.
      {:rustler, ">= 0.0.0"},
      {:vix,
       git: "https://github.com/hlindset/vix.git",
       ref: "1b9d9f9619a4fcc45bce0c4958bfa1168a7ac1c2",
       override: true},
      {:color, "~> 0.13"},
      {:req, "~> 0.5"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:boundary, "~> 0.10", runtime: false},
      {:excoveralls, ">= 0.0.0", only: [:test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:talan, "~> 0.2.1"},
      {:bandit, "~> 1.5", only: [:dev, :test]}
    ]

    # Real face detection needs `image_vision` AND its optional ONNX backend
    # `ortex` (a Rust/ONNX runtime): `image_vision`'s `Image.FaceDetection` is
    # compiled only when Ortex is configured (`if ImageVision.ortex_configured?()`),
    # and the YuNet model (~340 KB) downloads on first use.
    #
    # The fiddle app owns real detection in its own deps. Here, the library pulls
    # these only into the opt-in `:test` lane (`IMAGE_VISION=1`) for its own
    # detector test (`IMAGE_VISION=1 mix test --only image_vision`).
    ml_test_deps =
      if System.get_env("IMAGE_VISION") in ["1", "true"] do
        [
          {:image_vision, "~> 0.4", only: :test},
          {:ortex, "~> 0.1", only: :test}
        ]
      else
        []
      end

    imgproxy_diff_deps =
      if System.get_env("IMGPROXY_DIFF") in ["1", "true"] do
        [{:testcontainers, "~> 1.14", only: :test}]
      else
        []
      end

    base ++ ml_test_deps ++ imgproxy_diff_deps
  end

  defp aliases do
    [
      setup: ["deps.get"],
      test: ["test"]
    ]
  end
end
