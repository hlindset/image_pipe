defmodule ImagePipe.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/hlindset/image_pipe"
  @internal_doc_references [
    "ImagePipe.Cache.normalize_adapter_options/2",
    "ImagePipe.Delivery.Producer",
    "ImagePipe.Error.tag/1",
    "ImagePipe.Native.Config.validate!/1",
    "ImagePipe.Output",
    "ImagePipe.Output.Clamp.clamp_with_telemetry/4",
    "ImagePipe.Output.Encoder",
    "ImagePipe.Output.Encoder.stream_output/3",
    "ImagePipe.Output.Negotiate.negotiate_output/4",
    "ImagePipe.Output.Policy",
    "ImagePipe.Plug.Runner",
    "ImagePipe.Response.CachePolicy",
    "ImagePipe.Response.ErrorStatus",
    "ImagePipe.Response.Sender",
    "ImagePipe.Source.S3.Credentials.fetch/3",
    "ImagePipe.Source.S3.Credentials.validate/1",
    "ImagePipe.Source.S3.RefreshCache",
    "ImagePipe.Source.StreamError",
    "ImagePipe.Telemetry.Trace.Capture",
    "ImagePipe.Telemetry.Trace.FinchCapture",
    "ImagePipe.Telemetry.Trace.Stack.context/0"
  ]
  # ExDoc resolves remote typespecs without consulting skip_code_autolink_to.
  # These exact specs intentionally mention hidden runtime value types.
  @internal_typespec_references [
    "t:ImagePipe.Delivery.build_fun/0",
    "ImagePipe.Delivery.stream/5",
    "ImagePipe.Native.Identity.material/5",
    "ImagePipe.Output.EncodeSearch.run/3",
    "ImagePipe.Output.NativeJxlSearch.run/3",
    "t:ImagePipe.Transform.SourceGeometry.t/0",
    "t:ImagePipe.Transform.State.t/0"
  ]

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
        skip_code_autolink_to: @internal_doc_references,
        skip_undefined_reference_warnings_on: @internal_typespec_references,
        assets: %{"docs/assets" => "docs/assets"},
        extras: [
          "README.md",
          "CHANGELOG.md",
          "LICENSE.md",
          "docs/cache.md",
          {"docs/cdn-http-cache.md", title: "CDN HTTP Caching"},
          "docs/operational_notes.md",
          "docs/telemetry.md",
          "docs/debug_headers.md",
          {"docs/api_contract.md", title: "API Contract"},
          {"docs/execution_flow.md", title: "Execution Flow"},
          {"docs/source-network-policy.md", title: "Source Network Policy"},
          {"docs/content-aware-gravity.md", title: "Content-aware Cropping"},
          {"docs/cookbook/opentelemetry-jaeger.md", title: "OpenTelemetry → Jaeger"},
          "docs/transform_operations.md"
        ],
        groups_for_modules: [
          "Package API": [ImagePipe],
          "Plug API": [ImagePipe.Plug],
          API: [ImagePipe.Native, ~r/ImagePipe\.Native\..*/],
          "Plan Model": [ImagePipe.Plan, ~r/ImagePipe\.Plan\..*/],
          "Transform API": [ImagePipe.Transform, ~r/ImagePipe\.Transform\..*/],
          "Cache API": [ImagePipe.Cache, ~r/ImagePipe\.Cache\..*/],
          "Runtime Internals": [
            ~r/ImagePipe\.Source.*/,
            ~r/ImagePipe\.Output.*/,
            ~r/ImagePipe\.Response.*/,
            ImagePipe.Telemetry
          ]
        ]
      ],
      test_coverage: [tool: ExCoveralls],
      dialyzer: [
        plt_core_path: "priv/plts",
        plt_local_path: "priv/plts"
      ]
    ]
  end

  def application do
    [
      mod: {ImagePipe.Application, []},
      extra_applications: [:logger]
    ]
  end

  def ex_dna_options do
    [excluded_macros: [:alias]]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.html": :test,
        "autoquality.bench": :test,
        "autoquality.corpus": :test,
        "autoquality.corpus.capture": :test,
        "fixtures.gen_sources": :test,
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
    "A Plug-based image optimization server with a declarative path API."
  end

  defp package do
    [
      files: [
        "lib",
        "priv",
        "docs/cache.md",
        "docs/cdn-http-cache.md",
        "docs/execution_flow.md",
        "docs/api_contract.md",
        "docs/source-network-policy.md",
        "docs/content-aware-gravity.md",
        "docs/assets/demo-fiddle-desktop.png",
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
      {:image, "~> 0.72"},
      {:ssimulacra2, "~> 0.1.0"},
      {:butteraugli, "~> 0.1.0"},
      {:vix, "~> 0.41"},
      {:color, "~> 0.13"},
      {:req, "~> 0.7"},
      {:stream_data, "~> 1.0", only: [:test, :dev]},
      {:boundary, "~> 0.10", runtime: false},
      {:excoveralls, ">= 0.0.0", only: [:test], runtime: false},
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.5", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:talan, "~> 1.0"},
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

    # `testcontainers` provisions Docker for the opt-in AWS credential
    # integration smoke lane (`AWS_INTEGRATION`).
    testcontainers_deps =
      if System.get_env("AWS_INTEGRATION") in ["1", "true"] do
        [{:testcontainers, "~> 2.4", only: :test}]
      else
        []
      end

    base ++ ml_test_deps ++ testcontainers_deps
  end

  defp aliases do
    [
      "image_pipe.ex_dna": &run_ex_dna/1,
      setup: ["deps.get"],
      test: ["test"]
    ]
  end

  defp run_ex_dna(args) do
    options = ex_dna_options()

    excluded_macros =
      Enum.flat_map(options[:excluded_macros], &["--exclude-macro", Atom.to_string(&1)])

    Mix.Task.run("ex_dna", excluded_macros ++ args)
  end
end
