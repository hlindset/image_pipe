defmodule ImagePipe.ArchitectureBoundaryTest do
  use ExUnit.Case, async: true

  @request_source_response_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/request.ex",
    "lib/image_pipe/request/**/*.ex",
    "lib/image_pipe/source.ex",
    "lib/image_pipe/source/**/*.ex",
    "lib/image_pipe/response.ex",
    "lib/image_pipe/response/**/*.ex"
  ]
  @detector_forbidden_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/request.ex",
    "lib/image_pipe/request/**/*.ex",
    "lib/image_pipe/source.ex",
    "lib/image_pipe/source/**/*.ex",
    "lib/image_pipe/response.ex",
    "lib/image_pipe/response/**/*.ex",
    "lib/image_pipe/cache.ex",
    "lib/image_pipe/cache/**/*.ex",
    "lib/image_pipe/parser/**/*.ex",
    "lib/image_pipe/plan/**/*.ex"
  ]
  @parser_forbidden_globs [
    "lib/image_pipe/plug.ex",
    "lib/image_pipe/request.ex",
    "lib/image_pipe/request/**/*.ex",
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
  @parser_globs [
    "lib/image_pipe/parser.ex",
    "lib/image_pipe/parser/**/*.ex"
  ]
  @resolver_strategy_globs [
    "lib/image_pipe/parser/**/resolver.ex",
    "lib/image_pipe/parser/**/point_flow.ex"
  ]
  @resolver_strategy_forbidden_transform_names [:Chain, :State, :Materializer, :DecodePlanner]
  @cache_key_files ["lib/image_pipe/cache/key.ex"]
  @boundary_files %{
    ImagePipe.Application => "lib/application.ex",
    ImagePipe.Cache => "lib/image_pipe/cache.ex",
    ImagePipe.Config => "lib/image_pipe/config.ex",
    ImagePipe.Debug => "lib/image_pipe/debug.ex",
    ImagePipe.Error => "lib/image_pipe/error.ex",
    ImagePipe.Format => "lib/image_pipe/format.ex",
    ImagePipe.Output => "lib/image_pipe/output.ex",
    ImagePipe.Plan => "lib/image_pipe/plan.ex",
    ImagePipe.Parser => "lib/image_pipe/parser.ex",
    ImagePipe.Parser.IIIF => "lib/image_pipe/parser/iiif.ex",
    ImagePipe.Parser.Imgproxy => "lib/image_pipe/parser/imgproxy.ex",
    ImagePipe.Parser.TwicPics => "lib/image_pipe/parser/twic_pics.ex",
    ImagePipe.Renderer => "lib/image_pipe/renderer.ex",
    ImagePipe.Request => "lib/image_pipe/request.ex",
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
    :Directive,
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
  @post_fetch_transform_state_modules [
    ImagePipe.Transform.PlanExecutor
  ]
  @cache_prefetch_forbidden_transform_state_names [
    :PlanExecutor
  ]
  @runtime_forbidden_transform_execution_names [:PlanExecutor]
  @cache_prefetch_forbidden_transform_functions [
    :execute_plan
  ]

  test "parser boundary declarations stay limited to format, plan, renderer, and parser APIs" do
    parser = boundary_declaration(ImagePipe.Parser)
    imgproxy = boundary_declaration(ImagePipe.Parser.Imgproxy)
    iiif = boundary_declaration(ImagePipe.Parser.IIIF)
    twicpics = boundary_declaration(ImagePipe.Parser.TwicPics)

    assert_boundary_deps(parser, [
      ImagePipe.Config,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])

    # The Parser behaviour boundary must not export any concrete adapter: the core
    # never names a specific parser, so an adapter (imgproxy/…) can be ripped out
    # without editing the behaviour boundary.
    assert_boundary_exports(parser, [])

    assert_boundary_deps(imgproxy, [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])

    assert_boundary_exports(imgproxy, [ImagePipe.Parser.Imgproxy.SourceScheme])

    assert_boundary_deps(iiif, [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer
    ])

    assert_boundary_exports(iiif, [])

    assert_boundary_deps(twicpics, [
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])

    assert_boundary_exports(twicpics, [])

    assert_allowed_deps(parser, [
      ImagePipe.Config,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])

    assert_allowed_deps(imgproxy, [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])

    assert_allowed_deps(iiif, [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer
    ])

    assert_allowed_deps(twicpics, [
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Resolver,
      ImagePipe.Transform
    ])
  end

  test "request boundary declaration depends on generic facades only" do
    request = boundary_declaration(ImagePipe.Request)

    assert_boundary_deps(request, [
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.MaterialDigest,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ])

    refute_boundary_deps(request, [ImagePipe.Parser | concrete_transform_modules()])

    assert_boundary_exports(request, [
      ImagePipe.Request.HTTPCache,
      ImagePipe.Request.Options,
      ImagePipe.Request.Runner,
      ImagePipe.Request.SourceSessionSupervisor
    ])
  end

  test "application boundary owns OTP startup and depends on request lifecycle infrastructure" do
    application = boundary_declaration(ImagePipe.Application)

    assert_boundary_deps(application, [
      ImagePipe.Output,
      ImagePipe.Request,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ])

    assert_boundary_exports(application, [])
  end

  test "source boundary owns source identity and fetch context" do
    source = boundary_declaration(ImagePipe.Source)

    assert_boundary_deps(source, [ImagePipe.Error, ImagePipe.Plan, ImagePipe.Telemetry])

    refute_boundary_deps(source, [
      ImagePipe.Request,
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Output,
      ImagePipe.Transform,
      ImagePipe.Parser
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
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(response, [ImagePipe.Request, ImagePipe.Source, ImagePipe.Transform])

    assert_boundary_exports(response, [
      ImagePipe.Response.CORS,
      ImagePipe.Response.CacheHeaders,
      ImagePipe.Response.Json,
      ImagePipe.Response.PreparedStream,
      ImagePipe.Response.Sender
    ])
  end

  test "response delivery stays unaware of source sessions and cache staging" do
    forbidden_terms = [
      "ImagePipe.Request.SourceSession",
      "ImagePipe.Request.SourceSessionSupervisor",
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
        "#{file}:#{number} must not depend on #{term}; SourceSession owns cache staging"
      end

    assert violations == []
  end

  test "request code treats cache sinks as opaque cache values" do
    request_sources =
      "lib/image_pipe/request/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    forbidden_terms = [
      "ImagePipe.Cache.Sink",
      "Cache.Sink",
      ".Sink",
      "%Sink{",
      "%ImagePipe.Cache.Sink{"
    ]

    violations =
      for {file, source} <- request_sources,
          term <- forbidden_terms,
          String.contains?(source, term) do
        "#{file} must not inspect cache sink internals through #{term}"
      end

    assert violations == []
  end

  test "prepared stream wiring keeps lifecycle ownership in request and byte delivery in response" do
    response_sources =
      "lib/image_pipe/response/**/*.ex"
      |> Path.wildcard()
      |> Map.new(fn file -> {file, File.read!(file)} end)

    violations =
      for {file, source} <- response_sources,
          term <- ["SourceSession", "SourceSessionSupervisor"],
          String.contains?(source, term) do
        "#{file} must not reference #{term}; response delivery uses PreparedStream callbacks"
      end

    assert violations == []

    request = boundary_declaration(ImagePipe.Request)

    forbidden_exports = [
      ImagePipe.Request.SourceSession,
      ImagePipe.Request.SourceSession.Prepared,
      ImagePipe.Request.SourceSession.Request
    ]

    assert Enum.filter(request.exports, &(&1 in forbidden_exports)) == []
  end

  test "telemetry boundary remains a dependency-free facade" do
    telemetry = boundary_declaration(ImagePipe.Telemetry)

    assert_boundary_deps(telemetry, [])
    # ImagePipe.Telemetry.Trace is the opt-in span-tracer facade; the Plug edge calls
    # Trace.maybe_extract_inbound/1, so it is exported. Trace.Stack/Trace.Context are
    # exported because request/source code threads + adopts the trace context across the
    # request->SourceSession (hop A) and request->Producer (hop B) process seams (it
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

  test "telemetry trace capture does not reference concrete transform/source/request modules" do
    source = File.read!("lib/image_pipe/telemetry/trace/capture.ex")
    refute source =~ "ImagePipe.Transform.Operation"
    refute source =~ "ImagePipe.Source."
    refute source =~ "ImagePipe.Request."
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

    refute_boundary_deps(config, [
      ImagePipe.Parser,
      ImagePipe.Output,
      ImagePipe.Request,
      ImagePipe.Cache
    ])
  end

  test "output boundary depends only on format and plan data" do
    output = boundary_declaration(ImagePipe.Output)

    assert_boundary_deps(output, [
      ImagePipe.Config,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(output, [
      ImagePipe.Source,
      ImagePipe.Parser,
      ImagePipe.Request,
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Transform
    ])
  end

  test "renderer boundary depends only on the plan" do
    renderer = boundary_declaration(ImagePipe.Renderer)
    assert_boundary_deps(renderer, [ImagePipe.Plan])
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

  test "request, source, and response code does not inspect plan operation semantic staging" do
    violations =
      for file <- request_source_response_files(),
          violation <- plan_operation_semantic_references(file) do
        "#{file}:#{violation.line} must not call #{violation.module}.semantic?/1; use ImagePipe.Transform executable planning instead"
      end

    assert violations == []
  end

  test "request, source, and response code does not call removed or internal transform execution APIs" do
    violations =
      for file <- request_source_response_files(),
          violation <- runtime_forbidden_transform_execution_references(file) do
        "#{file}:#{violation.line} must not use #{violation.module}; execute canonical plans through ImagePipe.Transform.execute_plan/3"
      end

    assert violations == []
  end

  test "core code (plug, request, source, response, cache, output, plan) does not name concrete parser adapters" do
    imgproxy_violations =
      for file <- parser_forbidden_files(),
          violation <- imgproxy_parser_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; an adapter must be removable without changing the core — keep Imgproxy out of plug, request, source, response, cache, output, and plan code"
      end

    iiif_violations =
      for file <- parser_forbidden_files(),
          violation <- iiif_parser_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; an adapter must be removable without changing the core — keep IIIF out of plug, request, source, response, cache, output, and plan code"
      end

    assert imgproxy_violations == []
    assert iiif_violations == []
  end

  test "cache boundary declaration avoids post-fetch transform state dependencies" do
    cache = boundary_declaration(ImagePipe.Cache)

    assert_boundary_deps(cache, [
      ImagePipe.Debug,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.MaterialDigest,
      ImagePipe.Plan,
      ImagePipe.Output,
      ImagePipe.Telemetry
    ])

    refute_boundary_deps(cache, @post_fetch_transform_state_modules)

    assert_boundary_exports(cache, [
      ImagePipe.Cache.Entry,
      ImagePipe.Cache.Key,
      ImagePipe.Cache.FileSystem
    ])
  end

  test "bounded-mode FileSystem cache code stays within the cache boundary" do
    forbidden_terms = [
      "ImagePipe.Request",
      "ImagePipe.Source",
      "ImagePipe.Response",
      "ImagePipe.Parser"
    ]

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

    assert_boundary_deps(transform, [ImagePipe.Plan, ImagePipe.Resolver, ImagePipe.Telemetry])

    refute_boundary_deps(transform, [
      ImagePipe.Parser,
      ImagePipe.Request.Runner,
      ImagePipe.Request,
      ImagePipe.Source,
      ImagePipe.Response,
      ImagePipe.Cache,
      ImagePipe.Output
    ])

    assert_boundary_exports_include(transform, [
      ImagePipe.Transform.State,
      ImagePipe.Transform.Chain,
      ImagePipe.Transform.DecodePlanner,
      ImagePipe.Transform.Materializer,
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
      ImagePipe.Plan.Pipeline,
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
      ImagePipe.Plan.RenderContext,
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
      ImagePipe.Plan.Operation.Directive,
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

  test "cache key construction does not depend on post-fetch transform execution state" do
    violations =
      for file <- @cache_key_files,
          violation <- cache_prefetch_unsafe_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; final cache keys are prefetch-safe"
      end

    assert violations == []
  end

  test "parser code does not depend on executable transform operation modules" do
    # A parser's ImagePipe.Resolver strategy (e.g. imgproxy's :auto/no-enlarge
    # geometry-resolution column, #434) is a distinct concern from request
    # parsing/planning: it translates a semantic Plan operation into executable
    # transform operations, so it legitimately names concrete transform
    # modules — the Boundary deps (`parser` -> `Resolver, Transform`) already
    # permit this. Parser output — what PlanBuilder/Path/Options emit — must
    # still stay semantic-only, which is what this rule polices.
    resolver_strategy_files = MapSet.new(resolver_strategy_files())

    violations =
      for file <- parser_files(),
          not MapSet.member?(resolver_strategy_files, file),
          violation <- concrete_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; parser output is semantic Plan operations"
      end

    assert violations == []
  end

  test "a carried resolver strategy never touches execution state or pixel access" do
    # A Plan-carried resolver strategy (#434) resolves geometry only: it
    # translates a semantic Plan operation into executable transform ops and
    # threads strategy-local carry state. It must not reach into transform
    # execution state or pixel access — those stay owned by Chain/PlanExecutor.
    violations =
      for file <- resolver_strategy_files(),
          violation <- resolver_strategy_forbidden_transform_references(file) do
        "#{file}:#{violation.line} must not name #{violation.module}; " <>
          "a resolver strategy resolves geometry and never touches execution state or pixel access"
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

  defp parser_forbidden_files do
    @parser_forbidden_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp parser_files do
    @parser_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp resolver_strategy_files do
    @resolver_strategy_globs
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.sort()
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

  defp assert_allowed_deps(declaration, allowed_deps) do
    unexpected_deps = declaration |> boundary_dep_names() |> Kernel.--(allowed_deps)

    assert unexpected_deps == []
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

  defp concrete_transform_modules do
    Enum.map(@concrete_transform_names, &Module.concat(ImagePipe.Transform.Operation, &1))
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

  defp plan_operation_semantic_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {{:., meta, [{:__aliases__, _alias_meta, [:ImagePipe, :Plan, :Operation]}, :semantic?]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePipe.Plan.Operation") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Plan, :Operation]}, :semantic?]}, _call_meta,
         _args} = node,
        violations ->
          {node, [violation(meta, "Plan.Operation") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Operation]}, :semantic?]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "Operation") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp runtime_forbidden_transform_execution_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePipe, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&runtime_forbidden_transform_execution_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {{:., meta,
          [{:__aliases__, _alias_meta, [:ImagePipe, :Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePipe.Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:PlanExecutor]}, :execute]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "PlanExecutor.execute") | violations]}

        {:__aliases__, meta, [:ImagePipe, :Transform, module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "ImagePipe.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        {:__aliases__, meta, [module | _rest]} = node, violations
        when module in @runtime_forbidden_transform_execution_names ->
          {node, [violation(meta, "#{module}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_runtime_forbidden_transform_execution_child_duplicates()
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

  defp resolver_strategy_forbidden_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePipe, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&resolver_strategy_forbidden_transform_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Transform, module | _rest]} = node, violations
        when module in @resolver_strategy_forbidden_transform_names ->
          {node, [violation(meta, "ImagePipe.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in @resolver_strategy_forbidden_transform_names ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp resolver_strategy_forbidden_transform_alias({:__aliases__, _meta, [module]})
       when module in @resolver_strategy_forbidden_transform_names,
       do: "ImagePipe.Transform.#{module}"

  defp resolver_strategy_forbidden_transform_alias({:__aliases__, _meta, [module | _rest]})
       when module in @resolver_strategy_forbidden_transform_names,
       do: "ImagePipe.Transform.#{module}"

  defp resolver_strategy_forbidden_transform_alias(_alias), do: nil

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

  defp cache_prefetch_unsafe_transform_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {tag, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePipe, :Transform]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations
        when tag in [:alias, :import] ->
          grouped_aliases
          |> Enum.map(&cache_prefetch_unsafe_transform_alias/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.map(&violation(meta, &1))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Transform, module | _rest]} = node, violations
        when module in @cache_prefetch_forbidden_transform_state_names ->
          {node, [violation(meta, "ImagePipe.Transform.#{module}") | violations]}

        {:__aliases__, meta, [:Transform, module | _rest]} = node, violations
        when module in @cache_prefetch_forbidden_transform_state_names ->
          {node, [violation(meta, "Transform.#{module}") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:ImagePipe, :Transform]}, function]},
         _call_meta, _args} = node,
        violations
        when function in @cache_prefetch_forbidden_transform_functions ->
          {node, [violation(meta, "ImagePipe.Transform.#{function}") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform]}, function]}, _call_meta, _args} =
            node,
        violations
        when function in @cache_prefetch_forbidden_transform_functions ->
          {node, [violation(meta, "Transform.#{function}") | violations]}

        {{:., meta,
          [{:__aliases__, _alias_meta, [:ImagePipe, :Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "ImagePipe.Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:Transform, :PlanExecutor]}, :execute]},
         _call_meta, _args} = node,
        violations ->
          {node, [violation(meta, "Transform.PlanExecutor.execute") | violations]}

        {{:., meta, [{:__aliases__, _alias_meta, [:PlanExecutor]}, :execute]}, _call_meta, _args} =
            node,
        violations ->
          {node, [violation(meta, "PlanExecutor.execute") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
  end

  defp imgproxy_parser_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePipe, :Parser]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.filter(&imgproxy_parser_alias?/1)
          |> Enum.map(&violation(meta, imgproxy_parser_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Parser, :Imgproxy]} = node, violations ->
          {node, [violation(meta, "ImagePipe.Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:ImagePipe, :Parser, :Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "ImagePipe.Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Parser, :Imgproxy]} = node, violations ->
          {node, [violation(meta, "Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Parser, :Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "Parser.Imgproxy") | violations]}

        {:__aliases__, meta, [:Imgproxy]} = node, violations ->
          {node, [violation(meta, "Imgproxy") | violations]}

        {:__aliases__, meta, [:Imgproxy | _rest]} = node, violations ->
          {node, [violation(meta, "Imgproxy") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_grouped_alias_child_duplicates()
  end

  defp imgproxy_parser_alias?({:__aliases__, _meta, [:Imgproxy]}), do: true
  defp imgproxy_parser_alias?({:__aliases__, _meta, [:Imgproxy | _rest]}), do: true
  defp imgproxy_parser_alias?(_ast), do: false

  defp imgproxy_parser_module({:__aliases__, _meta, [:Imgproxy]}),
    do: "ImagePipe.Parser.Imgproxy"

  defp imgproxy_parser_module({:__aliases__, _meta, [:Imgproxy | _rest]}),
    do: "ImagePipe.Parser.Imgproxy"

  defp reject_grouped_alias_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(&(&1.module == "ImagePipe.Parser.Imgproxy"))
      |> MapSet.new(& &1.line)

    Enum.reject(
      violations,
      &(&1.module == "Imgproxy" and MapSet.member?(grouped_alias_lines, &1.line))
    )
  end

  defp iiif_parser_references(file) do
    {:ok, ast} = file |> File.read!() |> Code.string_to_quoted()

    {_ast, violations} =
      Macro.prewalk(ast, [], fn
        {:alias, meta,
         [
           {{:., _dot_meta, [{:__aliases__, _module_meta, [:ImagePipe, :Parser]}, :{}]},
            _call_meta, grouped_aliases}
         ]} = node,
        violations ->
          grouped_aliases
          |> Enum.filter(&iiif_parser_alias?/1)
          |> Enum.map(&violation(meta, iiif_parser_module(&1)))
          |> then(&{node, &1 ++ violations})

        {:__aliases__, meta, [:ImagePipe, :Parser, :IIIF]} = node, violations ->
          {node, [violation(meta, "ImagePipe.Parser.IIIF") | violations]}

        {:__aliases__, meta, [:ImagePipe, :Parser, :IIIF | _rest]} = node, violations ->
          {node, [violation(meta, "ImagePipe.Parser.IIIF") | violations]}

        {:__aliases__, meta, [:Parser, :IIIF]} = node, violations ->
          {node, [violation(meta, "Parser.IIIF") | violations]}

        {:__aliases__, meta, [:Parser, :IIIF | _rest]} = node, violations ->
          {node, [violation(meta, "Parser.IIIF") | violations]}

        {:__aliases__, meta, [:IIIF]} = node, violations ->
          {node, [violation(meta, "IIIF") | violations]}

        {:__aliases__, meta, [:IIIF | _rest]} = node, violations ->
          {node, [violation(meta, "IIIF") | violations]}

        node, violations ->
          {node, violations}
      end)

    violations
    |> Enum.reverse()
    |> Enum.uniq()
    |> reject_iiif_grouped_alias_child_duplicates()
  end

  defp iiif_parser_alias?({:__aliases__, _meta, [:IIIF]}), do: true
  defp iiif_parser_alias?({:__aliases__, _meta, [:IIIF | _rest]}), do: true
  defp iiif_parser_alias?(_ast), do: false

  defp iiif_parser_module({:__aliases__, _meta, [:IIIF]}),
    do: "ImagePipe.Parser.IIIF"

  defp iiif_parser_module({:__aliases__, _meta, [:IIIF | _rest]}),
    do: "ImagePipe.Parser.IIIF"

  defp reject_iiif_grouped_alias_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(&(&1.module == "ImagePipe.Parser.IIIF"))
      |> MapSet.new(& &1.line)

    Enum.reject(
      violations,
      &(&1.module == "IIIF" and MapSet.member?(grouped_alias_lines, &1.line))
    )
  end

  defp reject_runtime_forbidden_transform_execution_child_duplicates(violations) do
    grouped_alias_lines =
      violations
      |> Enum.filter(
        &(&1.module in [
            "ImagePipe.Transform.PlanExecutor"
          ])
      )
      |> MapSet.new(& &1.line)

    resolver_call_lines =
      violations
      |> Enum.filter(
        &(&1.module in [
            "PlanExecutor.execute",
            "Transform.PlanExecutor.execute"
          ])
      )
      |> MapSet.new(& &1.line)

    Enum.reject(violations, fn
      %{module: module, line: line}
      when module in ["PlanExecutor"] ->
        MapSet.member?(grouped_alias_lines, line) or MapSet.member?(resolver_call_lines, line)

      _violation ->
        false
    end)
  end

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

  defp cache_prefetch_unsafe_transform_alias({:__aliases__, _meta, [module]})
       when module in @cache_prefetch_forbidden_transform_state_names,
       do: "ImagePipe.Transform.#{module}"

  defp cache_prefetch_unsafe_transform_alias({:__aliases__, _meta, [module | _rest]})
       when module in @cache_prefetch_forbidden_transform_state_names,
       do: "ImagePipe.Transform.#{module}"

  defp cache_prefetch_unsafe_transform_alias(_alias), do: nil

  defp runtime_forbidden_transform_execution_alias({:__aliases__, _meta, [module]})
       when module in @runtime_forbidden_transform_execution_names,
       do: "ImagePipe.Transform.#{module}"

  defp runtime_forbidden_transform_execution_alias({:__aliases__, _meta, [module | _rest]})
       when module in @runtime_forbidden_transform_execution_names,
       do: "ImagePipe.Transform.#{module}"

  defp runtime_forbidden_transform_execution_alias(_alias), do: nil

  defp violation(meta, module) do
    %{line: Keyword.fetch!(meta, :line), module: module}
  end
end
