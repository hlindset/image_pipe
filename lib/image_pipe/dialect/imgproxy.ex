defmodule ImagePipe.Dialect.Imgproxy do
  @moduledoc """
  ImagePipe's imgproxy-compatible URL dialect, implemented as an
  `ImagePipe.Dialect` — mounted through `plug ImagePipe.Plug, dialect:
  ImagePipe.Dialect.Imgproxy, <flat config>`.

  The dialect owns the endpoint split, the signature verify (403 before any
  option parsing), the option grammar, the `exp`/geometry/`detector_required`
  gates, source translation, negotiation input, the `/info` render terminal,
  pipeline execution, and error rendering; the shared runner in
  `ImagePipe.Plug` owns the request lifecycle around them. It depends on the
  core; the core never depends on it.

  ## Everything decidable from the request is decided before the fetch

  Parser and planner rejections return before any source fetch or cache
  access [AGENTS.md, request safety]. The signature, the option grammar, and
  the `exp` gate are self-evidently pre-fetch, but the geometry is not: a
  request whose pipelines cannot assemble an operation list (`rs:fill` with
  no dimensions, a `dpr` with no rational) is only discovered by
  `ImagePipe.Dialect.Imgproxy.Assembly.operations/1`, which
  `ImagePipe.Dialect.Imgproxy.Pipeline` reaches at run time — after the
  fetch and the decode. `check_geometry/1` therefore runs the same pure
  function over every pipeline ahead of the fetch, so an unassemblable
  request rejects before any source fetch or cache access. The run-time
  call stays: it is the one that produces the operations, and re-running a
  pure function over a parsed request costs nothing next to a fetch.

  ## Response metadata rides the request, never the cache entry

  `Content-Disposition` and the `debug?` opt-in are delivery presentation,
  not response bytes: they are excluded from the identity material, so two
  requests differing only in `fn:` share one cache entry — and both the hit
  and the miss path build their `%Plan.Response{}` from the CURRENT request
  (`ImagePipe.Dialect.Imgproxy.ResponseMeta`), never from the stored entry.
  """

  use Boundary,
    top_level?: true,
    deps: [
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
    ],
    exports: [SourceScheme]

  @behaviour ImagePipe.Dialect

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.Config
  alias ImagePipe.Dialect.Imgproxy.Errors
  alias ImagePipe.Dialect.Imgproxy.Identity
  alias ImagePipe.Dialect.Imgproxy.InfoRenderer
  alias ImagePipe.Dialect.Imgproxy.Options
  alias ImagePipe.Dialect.Imgproxy.Path
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Dialect.Imgproxy.ResponseMeta
  alias ImagePipe.Dialect.Imgproxy.Signature
  alias ImagePipe.Dialect.Imgproxy.Source, as: ImgproxySource
  alias ImagePipe.Dialect.Imgproxy.SourceEncryption
  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Error
  alias ImagePipe.Plan.Operation, as: PlanOperation
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias Vix.Vips.Image, as: VipsImage

  # `/info` reads the header and nothing else, so it asks the decode planner for
  # no shrink at all: every field of a bare request is already the "no
  # preflight" answer.
  @info_decode_request %DecodePlanner.Request{}

  @doc """
  Encrypts a source URL into the segment used after imgproxy's `/enc/` marker.

  The helper returns only the encrypted source segment. It doesn't add the
  `/enc/` marker, processing options, output suffixes, or signatures.

  The key must be a hex string that decodes to a 16, 24, or 32 byte AES key.
  By default the helper uses a random 16 byte IV. Pass
  `iv: <<...::binary-size(16)>>` when the caller needs a deterministic segment.

  Returns `{:error, :invalid_source_url}` when the source URL isn't a binary,
  `{:error, :invalid_key}` when the key isn't valid hex AES key material,
  `{:error, :invalid_iv}` when `:iv` isn't 16 bytes, and
  `{:error, :invalid_options}` for non-keyword or unknown options.
  """
  @spec encrypt_source_url(binary(), binary(), keyword()) ::
          {:ok, binary()}
          | {:error, :invalid_source_url | :invalid_key | :invalid_iv | :invalid_options}
  def encrypt_source_url(source_url, hex_key, opts \\ []) do
    SourceEncryption.encrypt_source_url(source_url, hex_key, opts)
  end

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  # The [:parse] span (runner-wrapped) now brackets the endpoint split too —
  # a pure path-prefix check. The /info conn is prefix-stripped by
  # `split_endpoint/1`, matching upstream's signature-over-the-unprefixed-path
  # behavior; `prepare/3` gets the ORIGINAL conn, which is fine — it reads only
  # headers, never the path.
  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    result =
      case Path.split_endpoint(conn) do
        {:info, info_conn} -> parse_request(info_conn, config, :info)
        :image -> parse_request(conn, config, :image)
      end

    {result, parse_stop_metadata(result)}
  end

  # The `/info` terminal [spec §The /info cache path]. Skips three of the image
  # path's steps because none applies to an info request: the geometry check
  # has no operations to reject, negotiation has no format to select, and
  # there is no image body to attach a `Content-Disposition` to. The `exp`
  # gate and the signature still apply.
  #
  # `request/5`'s `:info` head drops the parsed pipelines and output for the same
  # reason, so none of the three can reach this terminal's identity.
  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{info?: true} = request, config) do
    with :ok <- check_expires(request, config),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config) do
      # /info has one fixed terminal: no format to select, nothing to vary
      # by or carry as output-policy identity material.
      negotiation = DialectNegotiation.terminal(:info)

      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation:
           {:ok, negotiation, Identity.material(request, negotiation, conn, config, nil)},
         response_meta: %PlanResponse{},
         operations: [],
         auto_rotate?: false,
         debug?: false,
         terminal: {:render, info_terminal()}
       }}
    end
  end

  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    with :ok <- check_expires(request, config),
         {:ok, operations} <- check_geometry(request),
         :ok <- check_detector(operations, config),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config),
         {:ok, %PlanResponse{} = response_meta} <- ResponseMeta.build(request, plan_source) do
      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation: fn -> negotiation_result(conn, request, operations, config) end,
         response_meta: response_meta,
         operations: operation_names(request),
         auto_rotate?: request.auto_rotate,
         debug?: response_meta.debug?,
         terminal: :image
       }}
    end
  end

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry),
    do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  # The three dialects' contract delegations are textually identical but
  # resolve through per-dialect aliases to different Request structs and
  # Pipeline modules — irreducible without a macro that would force a
  # naming convention on every dialect and hide the contract.
  # ex_dna:disable-for-next-line
  def execute(state, geometry, %Request{} = request, opts) do
    ImagePipe.Dialect.safe_transform(fn -> Pipeline.run(state, geometry, request, opts) end)
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  # This dialect's own client-reject reasons — the signature and `exp` gates,
  # both pre-fetch and pre-option-parse — get the client-error atom directly,
  # the same way `ImagePipe.Plug`'s parser errors always render
  # `:parser_error` regardless of the underlying reason. Two pre-fetch gates
  # are the exception, both plan-shape failures rather than syntax ones, and
  # both `:plan_error`: `Assembly.operations/1`'s geometry rejection
  # (`{:missing_dimensions, _}` — `Errors.send/3` still answers it with the
  # same 400 as every other parse reject), and `check_detector/2`'s
  # `{:detector, :unavailable}` (mirroring `ImagePipe.Plug`'s own
  # `:plan_error` for it).
  #
  # Everything else — Options/Path/Source translate rejects (`:unknown_option`,
  # `:invalid_option_segment`, `:invalid_source_url`, …), and the core-stage
  # reasons (`:source`, `:decode`, `:input_limit`, `:unsupported_output_format`,
  # `:encode`, `:session`, `:transform`) — defers to the shared classifier,
  # `ImagePipe.Telemetry.request_result/1`. That classifier already resolves
  # `{:source, _}` to `:source_error` for free; everything it does not
  # specifically recognize (including the long, open-ended tail of Options/Path
  # rejects) lands at its `:processing_error` default.
  @impl ImagePipe.Dialect
  def classify_error(:invalid_signature), do: :parser_error
  def classify_error({:invalid_signature_encoding, _signature}), do: :parser_error
  def classify_error({:unsupported_signature, _signature}), do: :parser_error
  def classify_error({:expired_request, _expires}), do: :parser_error
  def classify_error({:missing_dimensions, _resizing_type}), do: :plan_error
  def classify_error({:detector, :unavailable}), do: :plan_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})

  # -- extract → verify → split → parse ---------------------------------------

  # Extracts the signature, verifies it, splits off the source path, parses
  # the option segments, then merges the resolved output format from an
  # explicit source-path extension. Reads the dialect's FLAT config — no
  # `:imgproxy`-nested keyword.
  #
  # No `sig_key_index` stop metadata (native's `[:parse]` span carries one):
  # imgproxy's signature grammar has no key index to carry. `Signature.verify/3`
  # returns a bare `:ok` — it tries every configured key/salt pair with
  # `Enum.any?/2` and never reports which one matched.
  defp parse_request(%Plug.Conn{} = conn, config, endpoint) do
    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- Signature.verify(signature, signed_path, Keyword.fetch!(config, :signature)),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <- parse_options(option_segments, config),
         {:ok, source_path, source_format} <-
           parse_source(endpoint, source_kind, raw_source_path, config) do
      {:ok, request(endpoint, signature, source_path, source_format, request_options)}
    end
  end

  defp parse_options(option_segments, config),
    do: Options.parse(option_segments, Keyword.fetch!(config, :presets), config)

  # `/info` reads no output extension off the source: an `@jpg` suffix selects a
  # delivery format, and /info delivers JSON.
  defp parse_source(:image, source_kind, raw_source_path, config),
    do: Path.parse_source(source_kind, raw_source_path, config)

  defp parse_source(:info, source_kind, raw_source_path, config),
    do: Path.parse_source_no_extension(source_kind, raw_source_path, config)

  defp request(:image, signature, source_path, source_format, request_options) do
    %Request{
      signature: signature,
      source_kind: :plain,
      source_path: source_path,
      pipelines: request_options.pipelines,
      auto_rotate: request_options.auto_rotate,
      output: %{request_options.output | format: source_format || request_options.output.format},
      policy: request_options.policy,
      cache: request_options.cache,
      response: request_options.response
    }
  end

  # The `/info` request struct: `info?` set, `auto_rotate` forced off (the
  # reported orientation is the source's own header, so the decode must not
  # consume it), and the output untouched by the discarded source format.
  #
  # The parsed `pipelines` and `output` are DROPPED — `pipelines: []`, and
  # `output` reset to its no-intent default below. /info never runs a
  # pipeline and never encodes — the render terminal goes straight to
  # `source_info/2` with `@info_decode_request` — so nothing on this path
  # reads either field except `Identity.material/5`. Carrying them would mean
  # `/info/rs:fill:100:100/…` and `/info/…` got different cache keys and
  # different ETags for byte-identical bodies, forcing a client to re-download
  # identical content: exactly what the ETag's narrowness exists to prevent
  # (AGENTS.md). Dropping them here rather than teaching `Identity.material/5` to
  # ignore them for this terminal keeps the struct honest about what the request
  # will execute — an identity that folds in only what the struct carries cannot
  # regrow this bug when a field is added.
  #
  # `output` is not nilable on this struct (unlike `ImagePipe.Plan`), so the
  # defaults — no format, no quality, no encoder options — are the spelling
  # of "no output intent".
  defp request(:info, signature, source_path, _source_format, request_options) do
    %Request{
      signature: signature,
      source_kind: :plain,
      source_path: source_path,
      pipelines: [],
      info?: true,
      auto_rotate: false,
      output: Request.output_request(),
      policy: request_options.policy,
      cache: request_options.cache,
      response: request_options.response
    }
  end

  defp parse_stop_metadata({:ok, %Request{}}), do: %{result: :ok}

  # `error:` names WHICH parse failed — `:unknown_option`, `:invalid_format`,
  # `:missing_dimensions`, `:invalid_encrypted_source`. Telemetry is part of the
  # runtime observability contract (AGENTS.md) and `Error.tag/1` output is a
  # product-neutral, non-sensitive atom, so there is no reason to withhold it.
  #
  # This deliberately does NOT reproduce `ImagePipe.Plug`'s value, which is
  # the constant `:error` for every parse failure: its `wrap_parser_error/1`
  # re-wraps `{:error, reason}` as `{:error, {:parser, {:error, reason}}}`, so
  # `result_metadata/1`'s `Error.tag(error)` reads the tag of `{:error,
  # reason}` — the atom `:error` — and never reaches `reason`. Matching that
  # would carry the quirk into a chain that does not share the double-wrap,
  # to emit a constant conveying nothing.
  defp parse_stop_metadata({:error, reason}), do: %{result: :error, error: Error.tag(reason)}

  # -- pre-fetch gates --------------------------------------------------------

  # Mirrors `PlanBuilder.expires_plan/2` + `reject_expired_request/2`: `exp:0`
  # disables the gate outright (and never reads the clock), and the comparison
  # is strictly `expires < now`, so a request expiring this very second still
  # passes.
  defp check_expires(%Request{policy: %{expires: 0}}, _config), do: :ok

  defp check_expires(%Request{policy: %{expires: expires}}, config)
       when is_integer(expires) and expires > 0 do
    if expires < now_unix_seconds(config) do
      {:error, {:expired_request, expires}}
    else
      :ok
    end
  end

  defp now_unix_seconds(config) do
    config
    |> Keyword.fetch!(:clock)
    |> then(&DateTime.to_unix(&1.()))
  end

  # Pre-fetch geometry assembly, run here for its rejection only — see the
  # moduledoc. The operations themselves are produced (again) by
  # `Pipeline.run/4`, which owns the per-pipeline shape the operations are
  # assembled against. They are handed back here so `check_detector/2` can
  # read their guides without a third assembly pass.
  defp check_geometry(%Request{pipelines: pipelines}) do
    Enum.reduce_while(pipelines, {:ok, []}, fn pipeline_request, {:ok, acc} ->
      case Assembly.operations(pipeline_request) do
        {:ok, operations} -> {:cont, {:ok, acc ++ operations}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # Strict-mode capability gate, mirroring `ImagePipe.Plug`'s
  # `validate_detector_capability/2` (plug.ex): when the host opts into
  # `detector_required` and the request asks for content detection
  # (`g:obj:*` / `g:objw:*` -> a `{:detect, _}` guide), reject before any source
  # fetch or cache access when the configured detector is unavailable for the
  # requested classes, rather than silently degrading to attention. Availability
  # is class-dependent (a composite may own the face model but not the object
  # model), so the resolved classes are threaded through.
  #
  # The gate consults `detect_classes/1` ONLY — deliberately NOT `face_assist?/1`.
  # The framework's gate checks `Plan.detect_classes(plan) != nil` alone, while a
  # face-assist smart guide participates only in cache-key identity. Adding it to
  # the gate would invent a divergence, not close one.
  defp check_detector(operations, config) do
    case detect_classes(operations) do
      nil ->
        :ok

      classes ->
        if Keyword.get(config, :detector_required, false) and
             not Transform.detector_available?(
               Keyword.get(config, :detector, :default),
               Keyword.put(config, :classes, classes)
             ) do
          {:error, {:detector, :unavailable}}
        else
          :ok
        end
    end
  end

  # The detect-guide classes requested across the pipelines' operations, or `nil`
  # when none request detection. Mirrors `ImagePipe.Plan.detect_classes/1`'s exact
  # return contract (`:all | nonempty_list(String.t()) | nil`) over the dialect
  # operations' `{:detect, {spec, weights}}` guides. Task 6's cache-key identity
  # reuses it alongside `face_assist?/1`.
  @doc false
  @spec detect_classes([map()]) :: :all | nonempty_list(String.t()) | nil
  # ex_dna:disable-for-next-line
  def detect_classes(operations) do
    operations
    |> Enum.reduce_while([], fn op, acc ->
      case Map.get(op, :guide) do
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {classes, _weights}} when is_list(classes) -> {:cont, classes ++ acc}
        _ -> {:cont, acc}
      end
    end)
    |> case do
      :all -> :all
      [] -> nil
      classes -> classes |> Enum.uniq() |> Enum.sort()
    end
  end

  # True when any operation requests a face-assisted smart guide
  # (`{:smart, :face_assist}`). Mirrors `ImagePipe.Plan.face_assist?/1`. Not
  # consulted by the gate above (see its note); Task 6's cache-key identity does.
  @doc false
  @spec face_assist?([map()]) :: boolean()
  def face_assist?(operations) do
    Enum.any?(operations, &(Map.get(&1, :guide) == {:smart, :face_assist}))
  end

  # -- negotiation ------------------------------------------------------------

  # The thunk is invoked by the runner only after `Source.resolve/3`.
  # Negotiation, detector callbacks, and identity construction therefore keep
  # the chain's source-before-negotiation execution and exception precedence.
  defp negotiation_result(conn, %Request{} = request, operations, config) do
    case DialectNegotiation.negotiate(conn, Identity.plan_output(request), config) do
      {:ok, negotiation} ->
        {:ok, negotiation,
         Identity.material(
           request,
           negotiation,
           conn,
           config,
           detector_identity(operations, config)
         )}

      {:error, _reason} = error ->
        error
    end
  end

  # The resolved detector identity for cache-key/ETag material, computed ONCE per
  # request (before `Representation.build`, so the ETag and the key derive from a
  # single resolution). Fully mirrors `Request.Runner.with_detector_identity/2`,
  # INCLUDING the face-assist leg: identity is resolved when the pipelines request
  # detection (`detect_classes/1` — a `{:detect, _}` guide) OR a face-assisted
  # smart guide (`face_assist?/1`, whose attention point blends the detected face
  # centroid), with the framework's `["face"]` classes fallback. A disabled
  # detector (`Transform.detector_identity/2` returning nil) leaves the material's
  # `detector:` entry absent, same as no detection. Otherwise nil.
  defp detector_identity(operations, config) do
    detect_classes = detect_classes(operations)

    if detect_classes != nil or face_assist?(operations) do
      Transform.detector_identity(
        Keyword.get(config, :detector, :default),
        Keyword.put(config, :classes, detect_classes || ["face"])
      )
    else
      nil
    end
  end

  # -- the /info render terminal ----------------------------------------------

  defp info_terminal do
    %RenderTerminal{
      charset: :default,
      fun: fn resolved_source, config ->
        case source_info(resolved_source, config) do
          {:ok, %SourceInfo{} = info} ->
            {content_type, body} = InfoRenderer.render(info)
            {:ok, content_type, body}

          {:error, _reason} = error ->
            error
        end
      end
    }
  end

  defp source_info(resolved, config) do
    Decode.with_image(
      resolved,
      Keyword.put(config, :auto_rotate?, false),
      fn _geometry -> @info_decode_request end,
      fn state, geometry -> {:ok, build_source_info(state, geometry)} end
    )
  end

  # `width`/`height` are the STORED dimensions — `SourceInfo.display_dimensions/1`
  # is what applies the quarter-turn swap at render time. Reading them off
  # `geometry.display_dimensions` instead would swap them twice.
  defp build_source_info(state, %SourceGeometry{storage_dimensions: {width, height}} = geometry) do
    %SourceInfo{
      format: geometry.source_format,
      width: width,
      height: height,
      orientation: exif_orientation(state.image),
      byte_size: nil
    }
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _absent_or_invalid -> 1
    end
  end

  # The ordered semantic operation-name atoms across the request's pipelines —
  # the dialect counterpart of `Plan.operation_names/1`, over the same
  # `Assembly.operations/1` product `Pipeline.run/4` executes. Assembly cannot
  # reject here: `check_geometry/1` already ran the same pure function over
  # every pipeline before the fetch.
  defp operation_names(%Request{pipelines: pipelines}) do
    Enum.flat_map(pipelines, fn pipeline_request ->
      {:ok, operations} = Assembly.operations(pipeline_request)
      Enum.map(operations, &PlanOperation.name/1)
    end)
  end
end
