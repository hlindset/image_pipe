defmodule ImagePipe.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @request_source_response_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/source.ex",
    "lib/image_pipe/source/**/*.ex",
    "lib/image_pipe/response.ex",
    "lib/image_pipe/response/**/*.ex"
  ]
  @detector_forbidden_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/source.ex",
    "lib/image_pipe/source/**/*.ex",
    "lib/image_pipe/response.ex",
    "lib/image_pipe/response/**/*.ex",
    "lib/image_pipe/cache.ex",
    "lib/image_pipe/cache/**/*.ex",
    "lib/image_pipe/plan/**/*.ex"
  ]
  @core_surface_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/source.ex",
    "lib/image_pipe/source/**/*.ex",
    "lib/image_pipe/response.ex",
    "lib/image_pipe/response/**/*.ex",
    "lib/image_pipe/cache.ex",
    "lib/image_pipe/cache/**/*.ex",
    "lib/image_pipe/output.ex",
    "lib/image_pipe/output/**/*.ex",
    "lib/image_pipe/plan.ex",
    "lib/image_pipe/plan/**/*.ex"
  ]
  @transform_globs [
    "lib/image_pipe/transform.ex",
    "lib/image_pipe/transform/**/*.ex"
  ]
  # The shared runtime toolkit (delivery/decode/representation/config). It is
  # core — a dialect must be removable without editing it — so it belongs in
  # the "core must not name a dialect" grep alongside
  # plug/source/response/cache/output/plan/transform. The Boundary compiler
  # already enforces the real dep graph; this closes the grep's blind spot over
  # exactly that surface.
  @core_toolkit_globs [
    "lib/image_pipe/delivery.ex",
    "lib/image_pipe/delivery/**/*.ex",
    "lib/image_pipe/decode.ex",
    "lib/image_pipe/decode/**/*.ex",
    "lib/image_pipe/representation.ex",
    "lib/image_pipe/representation/**/*.ex",
    "lib/image_pipe/config.ex",
    "lib/image_pipe/config/**/*.ex"
  ]
  @dialect_forbidden_globs @core_surface_globs ++ @transform_globs ++ @core_toolkit_globs
  @boundary_files %{
    ImagePipe.Application => "lib/application.ex",
    ImagePipe.Cache => "lib/image_pipe/cache.ex",
    ImagePipe.Config => "lib/image_pipe/config.ex",
    ImagePipe.Debug => "lib/image_pipe/debug.ex",
    ImagePipe.Decode => "lib/image_pipe/decode.ex",
    ImagePipe.Delivery => "lib/image_pipe/delivery.ex",
    ImagePipe.Dialect => "lib/image_pipe/dialect.ex",
    ImagePipe.Dialect.Imgproxy => "lib/image_pipe/dialect/imgproxy.ex",
    ImagePipe.Native => "lib/image_pipe/native.ex",
    ImagePipe.Dialect.SharedConfig => "lib/image_pipe/dialect/shared_config.ex",
    ImagePipe.Error => "lib/image_pipe/error.ex",
    ImagePipe.Format => "lib/image_pipe/format.ex",
    ImagePipe.Output => "lib/image_pipe/output.ex",
    ImagePipe.Plan => "lib/image_pipe/plan.ex",
    ImagePipe.Plug => "lib/image_pipe/plug.ex",
    ImagePipe.Representation => "lib/image_pipe/representation.ex",
    ImagePipe.Response => "lib/image_pipe/response.ex",
    ImagePipe.Source => "lib/image_pipe/source.ex",
    ImagePipe.Telemetry => "lib/image_pipe/telemetry.ex",
    ImagePipe.Transform => "lib/image_pipe/transform.ex"
  }
  @concrete_plan_names [
    :Background,
    :Canvas,
    :CropGuided,
    :CropRegion,
    :Flip,
    :Padding,
    :Rotate,
    :Resize
  ]
  @concrete_transform_names [
    :Scale,
    :Contain,
    :Cover,
    :Crop,
    :Focus,
    :Resize,
    :Rotate,
    :Flip,
    :Background,
    :ExtendCanvas,
    :Padding,
    :AdaptiveResize
  ]
  test "plug boundary mounts native and owns the request lifecycle" do
    plug = boundary_declaration(ImagePipe.Plug)

    assert_boundary_deps(plug, [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Dialect,
      ImagePipe.Native,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ])

    refute_boundary_deps(plug, [
      ImagePipe.Dialect.Imgproxy
    ])

    # U2: the mount is the whole surface. `ImagePipe.Plug.DialectRunner` is the
    # internal lifecycle, not a host contract.
    assert_boundary_exports(plug, [])
  end

  test "dialect contract boundary pins the host-facing struct surface (U6)" do
    contract = boundary_declaration(ImagePipe.Dialect)

    assert_boundary_deps(contract, [
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Source,
      ImagePipe.Transform
    ])

    # Widening the contract hands every dialect transitive reach into the
    # runner's own lifecycle deps and hollows out the per-dialect
    # `refute_boundary_deps` pins below that prove no dialect can touch them.
    refute_boundary_deps(contract, [ImagePipe.Cache, ImagePipe.Delivery])

    # The five structs a dialect implementation names to satisfy the callbacks.
    # Anything added here is new public surface for every host dialect, so the
    # list is pinned exactly rather than by inclusion.
    assert_boundary_exports(contract, [
      ImagePipe.Dialect.DebugContext,
      ImagePipe.Dialect.Failure,
      ImagePipe.Dialect.Negotiation,
      ImagePipe.Dialect.RenderTerminal,
      ImagePipe.Dialect.Resolved
    ])
  end

  test "dialect native boundary declaration depends only on core toolkit facades" do
    dialect_native = boundary_declaration(ImagePipe.Native)

    assert_boundary_deps(dialect_native, [
      ImagePipe.Config,
      ImagePipe.Decode,
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ])

    # The Plug runner owns the cache and delivery lifecycle.
    refute_boundary_deps(dialect_native, [
      ImagePipe.Cache,
      ImagePipe.Delivery
    ])

    # A host implements `SourceScheme` to translate a custom `foo://` source
    # into the shared Plan.Source model. The native parser and lifecycle remain
    # concrete internal implementation.
    assert_boundary_exports(dialect_native, [ImagePipe.Native.SourceScheme])
  end

  test "the plug and request lifecycle have no dependency on compatibility implementations" do
    files =
      ["lib/image_pipe/plug.ex" | Path.wildcard("lib/image_pipe/plug/**/*.ex")]
      |> Enum.uniq()
      |> Enum.sort()

    violations =
      for file <- files,
          {line, number} <-
            file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          Regex.match?(~r/Dialect\.Imgproxy\b/, line) do
        "#{file}:#{number} names a concrete dialect: #{String.trim(line)}"
      end

    assert violations == [],
           "native request orchestration must not depend on compatibility implementations: " <>
             inspect(violations)
  end

  test "dialect imgproxy boundary declaration depends only on core toolkit facades" do
    dialect_imgproxy = boundary_declaration(ImagePipe.Dialect.Imgproxy)

    assert_boundary_deps(dialect_imgproxy, [
      ImagePipe.Config,
      ImagePipe.Decode,
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ])

    # Same rule as the native dialect: only core toolkit facades.
    # `ImagePipe.Config` is the one dep native does not take — this dialect's
    # `Config` splits its flat host keyword three ways and validates the neutral
    # half through the core config boundary, which is a core facade. The runner
    # in `ImagePipe.Plug` owns the cache and delivery lifecycle, so those deps
    # are gone too.
    refute_boundary_deps(dialect_imgproxy, [
      ImagePipe.Cache,
      ImagePipe.Delivery
    ])

    # `SourceScheme` is the one export: a host implements it to translate a
    # custom `foo://` source scheme. Nothing else in the dialect is a host
    # contract, so nothing else is exported.
    assert_boundary_exports(dialect_imgproxy, [ImagePipe.Dialect.Imgproxy.SourceScheme])
  end

  test "dialect SharedConfig boundary declaration stays product-neutral" do
    shared_config = boundary_declaration(ImagePipe.Dialect.SharedConfig)

    assert_boundary_deps(shared_config, [
      ImagePipe.Cache,
      ImagePipe.Format,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ])

    assert_boundary_exports(shared_config, [])
  end

  test "decode boundary declaration depends only on the core fetch/decode toolkit" do
    decode = boundary_declaration(ImagePipe.Decode)

    assert_boundary_deps(decode, [
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ])

    # The shared fetch/decode bracket must not reach into the cache, config,
    # output, renderer, or response layers.
    refute_boundary_deps(decode, [
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Output,
      ImagePipe.Response
    ])

    assert_boundary_exports(decode, [])
  end

  test "delivery boundary declaration depends only on core streaming/cache facades" do
    delivery = boundary_declaration(ImagePipe.Delivery)

    # `ImagePipe.Output` is a pinned-but-currently-unused declared dep (a known
    # dead entry left by the extraction); this pins the declared list as-is.
    assert_boundary_deps(delivery, [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ])

    # The shared delivery primitive must not reach into the renderer or config
    # layers, and must never name a concrete dialect.
    refute_boundary_deps(delivery, [ImagePipe.Config])

    assert_boundary_exports(delivery, [ImagePipe.Delivery.StreamPull])
  end

  test "core and transform code does not name a dialect" do
    # Source/response/cache/output/plan/transform stay independent of URL
    # parsing. The mount selects the native implementation.
    exempt = ["lib/image_pipe/plug.ex"]

    violations =
      for file <- dialect_forbidden_files(),
          file not in exempt,
          violation <- dialect_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; " <>
          "a dialect must be removable without changing the core"
      end

    assert violations == []
  end

  test "the dialect-forbidden grep excludes the dialect directory" do
    dialect_files = Path.wildcard("lib/image_pipe/dialect/**/*.ex")

    assert dialect_files != []
    assert Enum.all?(dialect_files, &(&1 not in dialect_forbidden_files()))
  end

  test "application boundary owns OTP startup" do
    application = boundary_declaration(ImagePipe.Application)

    assert_boundary_deps(application, [
      ImagePipe.Output,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ])

    assert_boundary_exports(application, [])
  end

  test "source boundary owns source identity and fetch context" do
    source = boundary_declaration(ImagePipe.Source)

    assert_boundary_deps(source, [ImagePipe.Error, ImagePipe.Plan, ImagePipe.Telemetry])

    refute_boundary_deps(source, [
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Output,
      ImagePipe.Transform
    ])

    assert_boundary_exports(source, [
      ImagePipe.Source.CacheSemantics,
      ImagePipe.Source.Resolved,
      ImagePipe.Source.Response,
      ImagePipe.Source.StreamError,
      ImagePipe.Source.HTTP,
      ImagePipe.Source.File,
      ImagePipe.Source.S3,
      ImagePipe.Source.S3.RefreshCache,
      ImagePipe.Source.S3.CredentialProvider,
      ImagePipe.Source.S3.CredentialWarmup
    ])
  end

  test "response boundary owns plug response delivery" do
    response = boundary_declaration(ImagePipe.Response)

    assert_boundary_deps(response, [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(response, [ImagePipe.Source, ImagePipe.Transform])

    assert_boundary_exports(response, [
      ImagePipe.Response.CORS,
      ImagePipe.Response.CacheHeaders,
      ImagePipe.Response.CachePolicy,
      ImagePipe.Response.Conditional,
      ImagePipe.Response.ErrorStatus,
      ImagePipe.Response.Json,
      ImagePipe.Response.PreparedStream,
      ImagePipe.Response.Sender
    ])
  end

  test "response delivery stays unaware of delivery sessions and cache staging" do
    forbidden_terms = [
      "ImagePipe.Delivery",
      "ImagePipe.Cache.Sink",
      "Cache.open_sink",
      "Cache.write_chunk",
      "Cache.commit_sink",
      "Cache.abort_sink",
      "Cache.put"
    ]

    violations =
      for file <- [
            "lib/image_pipe/response/prepared_stream.ex",
            "lib/image_pipe/response/sender.ex"
          ],
          File.exists?(file),
          {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          term <- forbidden_terms,
          String.contains?(line, term) do
        "#{file}:#{number} must not depend on #{term}; ImagePipe.Delivery owns cache staging"
      end

    assert violations == []
  end

  test "response code delivers bytes through PreparedStream callbacks, not delivery sessions" do
    response_sources =
      "lib/image_pipe/response/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    violations =
      for {file, source} <- response_sources,
          term <- ["ImagePipe.Delivery"],
          String.contains?(source, term) do
        "#{file} must not reference #{term}; response delivery uses PreparedStream callbacks"
      end

    assert violations == []
  end

  test "telemetry boundary remains a dependency-free facade" do
    telemetry = boundary_declaration(ImagePipe.Telemetry)

    assert_boundary_deps(telemetry, [])
    # ImagePipe.Telemetry.Trace is the opt-in span-tracer facade; the Plug edge calls
    # Trace.maybe_extract_inbound/1, so it is exported. Trace.Stack/Trace.Context are
    # exported because runner/source code threads + adopts the trace context across the
    # runner->delivery-coordinator (hop A) and runner->producer (hop B) process seams (it
    # calls only these generic Trace.* modules, never concrete transform ops).
    # Trace.ReqStep is exported because the source Req-client build site attaches it to
    # trace outbound fetches as a logical client span. Trace.Span and Trace.Exporter are
    # exported because a host implements the exporter behaviour (Trace.Exporter) and
    # receives captured spans (Trace.Span) — that is the public exporter contract.
    # Trace.OpenTelemetryExporter is the built-in opt-in exporter a host names directly
    # in attach_tracer/1, so it is a public entry point (it uses only the public
    # OpenTelemetry API; the boundary stays dependency-free).
    # Trace.OtelReplay is exported solely so ImagePipe.Application can supervise it; it is
    # exported-but-internal (@moduledoc false), the same posture as Trace.Stack.
    assert_boundary_exports(telemetry, [
      ImagePipe.Telemetry.Trace,
      ImagePipe.Telemetry.Trace.Stack,
      ImagePipe.Telemetry.Trace.Context,
      ImagePipe.Telemetry.Trace.Span,
      ImagePipe.Telemetry.Trace.Exporter,
      ImagePipe.Telemetry.Trace.ReqStep,
      ImagePipe.Telemetry.Trace.OpenTelemetryExporter,
      ImagePipe.Telemetry.Trace.OtelReplay
    ])
  end

  test "telemetry trace capture does not reference concrete transform or source modules" do
    source = File.read!("lib/image_pipe/telemetry/trace/capture.ex")
    refute source =~ "ImagePipe.Transform.Operation"
    refute source =~ "ImagePipe.Source."
  end

  test "CropScore delegates all SSIMULACRA2 access through the metric runtime" do
    source = File.read!("lib/image_pipe/output/ssim2_metric/crop_score.ex")
    refute source =~ "Ssimulacra2.Vix", "CropScore must not reference the raw Ssimulacra2 NIF"

    refute source =~ "Ssimulacra2.Reference",
           "CropScore must not reference the raw Ssimulacra2 NIF"
  end

  test "error boundary remains a dependency-free helper" do
    error = boundary_declaration(ImagePipe.Error)

    assert_boundary_deps(error, [])
    assert_boundary_exports(error, [])
  end

  test "debug boundary depends only on plan and exports debug header modules" do
    debug = boundary_declaration(ImagePipe.Debug)

    assert_boundary_deps(debug, [ImagePipe.Plan])

    assert_boundary_exports(debug, [
      ImagePipe.Debug.Headers,
      ImagePipe.Debug.Info,
      ImagePipe.Debug.Timing
    ])
  end

  test "format boundary remains dependency-free" do
    format = boundary_declaration(ImagePipe.Format)

    assert_boundary_deps(format, [])
    assert_boundary_exports(format, [ImagePipe.Format.Detector])
  end

  test "config boundary depends only on format and plan, exports nothing" do
    config = boundary_declaration(ImagePipe.Config)

    assert_boundary_deps(config, [ImagePipe.Plan])
    assert_boundary_exports(config, [])

    refute_boundary_deps(config, [ImagePipe.Output, ImagePipe.Cache])
  end

  test "output boundary depends only on format and plan data" do
    output = boundary_declaration(ImagePipe.Output)

    assert_boundary_deps(output, [
      ImagePipe.Config,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(output, [
      ImagePipe.Source,
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Transform
    ])
  end

  test "request, source, and response code does not depend on concrete transform modules" do
    violations =
      for file <- request_source_response_files(),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use ImagePipe.Transform dispatch instead"
      end

    assert violations == []
  end

  test "request, source, and response code does not depend on concrete plan operation modules" do
    violations =
      for file <- request_source_response_files(),
          violation <- concrete_plan_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; use generic Plan/Transform facades instead"
      end

    assert violations == []
  end

  test "request, plug, source, response, and cache code does not name concrete detector adapters" do
    violations =
      for file <- detector_forbidden_files(),
          violation <- concrete_detector_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; resolve detectors through the ImagePipe.Transform facade"
      end

    assert violations == []
  end

  test "cache boundary declaration avoids post-fetch transform state dependencies" do
    cache = boundary_declaration(ImagePipe.Cache)

    assert_boundary_deps(cache, [
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(cache, [ImagePipe.Transform])

    assert_boundary_exports(cache, [
      ImagePipe.Cache.Entry,
      ImagePipe.Cache.Key,
      ImagePipe.Cache.FileSystem
    ])
  end

  test "representation boundary declaration depends only on cache and material digest" do
    representation = boundary_declaration(ImagePipe.Representation)

    assert_boundary_deps(representation, [ImagePipe.Cache, ImagePipe.MaterialDigest])
    refute_boundary_deps(representation, [ImagePipe.Response])

    assert_boundary_exports(representation, [
      ImagePipe.Representation.IdentityMaterial
    ])
  end

  test "bounded-mode FileSystem cache code stays within the cache boundary" do
    forbidden_terms = ["ImagePipe.Source", "ImagePipe.Response"]

    cache_filesystem_sources =
      [
        "lib/image_pipe/cache/file_system.ex"
        | Path.wildcard("lib/image_pipe/cache/file_system/**/*.ex")
      ]
      |> Map.new(fn file -> {file, File.read!(file)} end)

    violations =
      for {file, source} <- cache_filesystem_sources,
          {line, number} <- source |> String.split("\n") |> Enum.with_index(1),
          term <- forbidden_terms,
          String.contains?(line, term) do
        "#{file}:#{number} must not depend on #{term}; " <>
          "bounded-mode cache code stays within the ImagePipe.Cache boundary"
      end

    assert violations == []
  end

  test "transform boundary declaration depends on plan and not higher layers" do
    transform = boundary_declaration(ImagePipe.Transform)

    assert_boundary_deps(transform, [ImagePipe.Plan, ImagePipe.Telemetry])

    refute_boundary_deps(transform, [
      ImagePipe.Source,
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Output
    ])

    assert_boundary_exports_include(transform, [
      ImagePipe.Transform.State,
      ImagePipe.Transform.Chain,
      ImagePipe.Transform.DecodePlanner,
      ImagePipe.Transform.DecodePlanner.Request,
      ImagePipe.Transform.Materializer,
      ImagePipe.Transform.SourceGeometry,
      ImagePipe.Transform.Operation.Resize,
      ImagePipe.Transform.Operation.ExtendCanvas,
      ImagePipe.Transform.Operation.Padding,
      ImagePipe.Transform.Operation.Background,
      ImagePipe.Transform.Operation.Bitonal,
      ImagePipe.Transform.Operation.Crop,
      ImagePipe.Transform.Operation.Blur,
      ImagePipe.Transform.Operation.Sharpen,
      ImagePipe.Transform.Operation.Pixelate,
      ImagePipe.Transform.Operation.Monochrome,
      ImagePipe.Transform.Operation.Duotone,
      ImagePipe.Transform.Operation.Gray,
      ImagePipe.Transform.Operation.Brightness,
      ImagePipe.Transform.Operation.Contrast,
      ImagePipe.Transform.Operation.Saturation
    ])
  end

  test "plan boundary exports canonical modules and depends only on formats" do
    plan = boundary_declaration(ImagePipe.Plan)

    assert_boundary_deps(plan, [ImagePipe.Format])

    assert_boundary_exports(plan, [
      ImagePipe.Plan.Output,
      ImagePipe.Plan.Output.QualitySearch,
      ImagePipe.Plan.Output.QualitySearch.Metric,
      ImagePipe.Plan.Output.QualitySearch.Size,
      ImagePipe.Plan.Output.QualitySearch.Ssimulacra2,
      ImagePipe.Plan.Output.QualitySearch.Butteraugli,
      ImagePipe.Plan.Output.JpegOptions,
      ImagePipe.Plan.Output.PngOptions,
      ImagePipe.Plan.Output.WebpOptions,
      ImagePipe.Plan.Output.AvifOptions,
      ImagePipe.Plan.Output.JxlOptions,
      ImagePipe.Plan.Response,
      ImagePipe.Plan.SourceInfo,
      ImagePipe.Plan.Color,
      ImagePipe.Plan.KeyData,
      ImagePipe.Plan.Measure,
      ImagePipe.Plan.Source,
      ImagePipe.Plan.Source.Identity,
      ImagePipe.Plan.Source.Path,
      ImagePipe.Plan.Source.URL,
      ImagePipe.Plan.Source.Object,
      ImagePipe.Plan.Source.Reference,
      ImagePipe.Plan.Operation,
      ImagePipe.Plan.Operation.Background,
      ImagePipe.Plan.Operation.Bitonal,
      ImagePipe.Plan.Operation.Blur,
      ImagePipe.Plan.Operation.Brightness,
      ImagePipe.Plan.Operation.Canvas,
      ImagePipe.Plan.Operation.Colorize,
      ImagePipe.Plan.Operation.Contrast,
      ImagePipe.Plan.Operation.CropGuided,
      ImagePipe.Plan.Operation.CropRegion,
      ImagePipe.Plan.Operation.Duotone,
      ImagePipe.Plan.Operation.Flip,
      ImagePipe.Plan.Operation.Gradient,
      ImagePipe.Plan.Operation.Gray,
      ImagePipe.Plan.Operation.Monochrome,
      ImagePipe.Plan.Operation.Padding,
      ImagePipe.Plan.Operation.Pixelate,
      ImagePipe.Plan.Operation.Rotate,
      ImagePipe.Plan.Operation.Resize,
      ImagePipe.Plan.Operation.Saturation,
      ImagePipe.Plan.Operation.Sharpen,
      ImagePipe.Plan.Operation.Trim
    ])
  end

  test "external color dependency stays behind the Plan color module" do
    allowed_files = MapSet.new(["lib/image_pipe/plan/color.ex"])

    violations =
      for file <- Path.wildcard("lib/**/*.ex"),
          not MapSet.member?(allowed_files, file),
          line <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          external_color_reference?(line) do
        {text, number} = line
        "#{file}:#{number} must not call or name external Color dependency APIs: #{text}"
      end

    assert violations == []
  end

  defp request_source_response_files do
    @request_source_response_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
  end

  defp detector_forbidden_files do
    @detector_forbidden_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dialect_forbidden_files do
    @dialect_forbidden_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp dialect_references(file) do
    for {line, number} <- file |> File.read!() |> String.split("\n") |> Enum.with_index(1),
        module <- ["ImagePipe.Dialect", "ImagePipe.Native"],
        String.contains?(line, module),
        do: %{line: number, module: module}
  end

  defp boundary_declaration(module) do
    file = Map.fetch!(@boundary_files, module)
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    opts =
      ast
      |> boundary_module_ast(module)
      |> boundary_use_opts()

    %{
      module: module,
      deps: opts |> Keyword.get(:deps, []) |> Enum.map(&normalize_boundary_dep/1),
      exports: opts |> Keyword.get(:exports, []) |> normalize_boundary_exports(module)
    }
  end

  defp assert_boundary_deps(declaration, expected_deps) do
    actual_deps = boundary_dep_names(declaration)

    assert actual_deps == Enum.sort(expected_deps)
    assert Enum.all?(declaration.deps, &runtime_dep?/1)
  end

  defp refute_boundary_deps(declaration, forbidden_deps) do
    forbidden_deps = MapSet.new(forbidden_deps)

    violations =
      declaration
      |> boundary_dep_names()
      |> Enum.filter(&MapSet.member?(forbidden_deps, &1))

    assert violations == []
  end

  defp assert_boundary_exports(declaration, expected_exports) do
    assert declaration.exports == Enum.sort(expected_exports)
  end

  defp assert_boundary_exports_include(declaration, expected_exports) do
    missing_exports = Enum.sort(expected_exports) -- declaration.exports

    assert missing_exports == []
  end

  defp external_color_reference?({line, _number}) do
    direct_external_color_module?(line) or
      external_color_call?(line)
  end

  defp direct_external_color_module?(line) do
    Regex.match?(~r/\balias\s+Color\b/, line) or
      Regex.match?(~r/%Color\./, line) or
      Regex.match?(~r/\bColor\.(SRGB|HSL|HSV|Lab|LCH|XYZ|new|parse|convert)\b/, line)
  end

  defp external_color_call?(line) do
    case Regex.run(~r/\bColor\.([a-zA-Z_][a-zA-Z0-9_]*[?!]?)/, line) do
      [_match, function] ->
        function not in [
          "alpha",
          "t",
          "white",
          "rgb",
          "rgb_hex",
          "rgba",
          "with_alpha",
          "valid?",
          "key_data",
          "to_rgb_list",
          "to_rgba_list"
        ]

      nil ->
        false
    end
  end

  defp boundary_dep_names(declaration) do
    declaration.deps
    |> Enum.map(fn {dep, _mode} -> dep end)
    |> Enum.sort()
  end

  defp runtime_dep?({_dep, :runtime}), do: true
  defp runtime_dep?({_dep, _mode}), do: false

  defp boundary_module_ast(ast, module) do
    {_ast, module_ast} =
      Macro.prewalk(ast, nil, fn
        {:defmodule, _meta, [{:__aliases__, _module_meta, parts}, [do: block]]} = node, acc ->
          case Module.concat(parts) do
            ^module -> {node, block}
            _other -> {node, acc}
          end

        node, acc ->
          {node, acc}
      end)

    module_ast
  end

  defp boundary_use_opts(module_ast) do
    {_ast, opts} =
      Macro.prewalk(module_ast, nil, fn
        {:use, _meta, [{:__aliases__, _boundary_meta, [:Boundary]}, opts]} = node, _acc
        when is_list(opts) ->
          {node, opts}

        node, acc ->
          {node, acc}
      end)

    opts
  end

  defp normalize_boundary_dep({dep, mode}) when mode in [:compile, :runtime] do
    {module_alias(dep), mode}
  end

  defp normalize_boundary_dep(dep), do: {module_alias(dep), :runtime}

  defp normalize_boundary_exports(:all, _boundary), do: :all

  defp normalize_boundary_exports(exports, boundary) do
    exports
    |> Enum.map(&boundary_export_module(boundary, &1))
    |> Enum.sort()
  end

  defp boundary_export_module(boundary, {export, _opts}) do
    boundary_export_module(boundary, export)
  end

  defp boundary_export_module(_boundary, {:__aliases__, _meta, [:ImagePipe | _rest] = parts}) do
    Module.concat(parts)
  end

  defp boundary_export_module(boundary, {:__aliases__, _meta, parts}) do
    Module.concat([boundary | parts])
  end

  defp module_alias({:__aliases__, _meta, parts}), do: Module.concat(parts)

  defp concrete_plan_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&concrete_plan_grouped_alias(grouped_alias_prefix, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, concrete_plan_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Plan, :Operation, operation | _rest]} = node,
        violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, concrete_plan_module(operation)) | violations]}

        {:__aliases__, meta, [:Plan, :Operation, operation | _rest]} = node, violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, "Plan.Operation.#{operation}") | violations]}

        {:__aliases__, meta, [:Operation, operation | _rest]} = node, violations
        when operation in @concrete_plan_names ->
          {node, [violation(meta, "Operation.#{operation}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp concrete_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&concrete_transform_grouped_alias(grouped_alias_prefix, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, concrete_transform_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Transform, :Operation, transform | _rest]} = node,
        violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, concrete_transform_module(transform)) | violations]}

        {:__aliases__, meta, [:Transform, :Operation, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Transform.Operation.#{transform}") | violations]}

        {:__aliases__, meta, [:Operation, transform | _rest]} = node, violations
        when transform in @concrete_transform_names ->
          {node, [violation(meta, "Operation.#{transform}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp concrete_detector_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [grouped_alias_prefix, :{}]}, _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&concrete_detector_grouped_alias(grouped_alias_prefix, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Transform, :Detector, submodule | _rest]} = node,
        violations ->
          {node, [violation(meta, "ImagePipe.Transform.Detector.#{submodule}") | violations]}

        {:__aliases__, meta, [:Transform, :Detector, submodule | _rest]} = node, violations ->
          {node, [violation(meta, "Transform.Detector.#{submodule}") | violations]}

        {:__aliases__, meta, [:Detector, submodule | _rest]} = node, violations ->
          {node, [violation(meta, "Detector.#{submodule}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp concrete_detector_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_detector_module()
  end

  defp concrete_detector_module([:ImagePipe, :Transform, :Detector, submodule | _rest]),
    do: "ImagePipe.Transform.Detector.#{submodule}"

  defp concrete_detector_module([:Transform, :Detector, submodule | _rest]),
    do: "Transform.Detector.#{submodule}"

  defp concrete_detector_module([:Detector, submodule | _rest]),
    do: "Detector.#{submodule}"

  defp concrete_detector_module(_parts), do: nil

  defp concrete_transform_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_transform_name()
  end

  defp concrete_plan_grouped_alias(prefix, alias) do
    prefix
    |> alias_parts()
    |> Kernel.++(grouped_alias_parts(alias))
    |> concrete_plan_name()
  end

  defp concrete_plan_name([:ImagePipe, :Plan, :Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name([:Plan, :Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name([:Operation, operation | _rest])
       when operation in @concrete_plan_names,
       do: operation

  defp concrete_plan_name(_parts), do: nil

  defp concrete_transform_name([:ImagePipe, :Transform, :Operation, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name([:Transform, :Operation, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name([:Operation, transform | _rest])
       when transform in @concrete_transform_names,
       do: transform

  defp concrete_transform_name(_parts), do: nil

  defp grouped_alias_parts({:__aliases__, _meta, parts}), do: parts

  defp grouped_alias_parts({{:., _dot_meta, [prefix, :{}]}, _call_meta, _grouped_aliases}),
    do: alias_parts(prefix)

  defp grouped_alias_parts(_alias), do: []

  defp alias_parts({:__aliases__, _meta, parts}), do: parts
  defp alias_parts(_alias), do: []

  defp concrete_transform_module({:__aliases__, _meta, [transform]}),
    do: concrete_transform_module(transform)

  defp concrete_transform_module({:__aliases__, _meta, [transform | _rest]}),
    do: concrete_transform_module(transform)

  defp concrete_transform_module(transform), do: "ImagePipe.Transform.Operation.#{transform}"

  defp concrete_plan_module({:__aliases__, _meta, [operation]}),
    do: concrete_plan_module(operation)

  defp concrete_plan_module({:__aliases__, _meta, [operation | _rest]}),
    do: concrete_plan_module(operation)

  defp concrete_plan_module(operation), do: "ImagePipe.Plan.Operation.#{operation}"

  defp violation(meta, module) do
    %{line: Keyword.fetch!(meta, :line), module: module}
  end
end
