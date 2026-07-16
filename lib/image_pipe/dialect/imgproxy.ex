defmodule ImagePipe.Dialect.Imgproxy do
  @moduledoc """
  Plug entry point for ImagePipe's imgproxy-compatible URL dialect.

  Unlike `ImagePipe.Plug` (which dispatches through the framework's
  `Parser`/`Request`/`Resolver`/`Renderer` stack), this dialect owns its
  whole request chain end to end, assembled directly from ImagePipe's core
  toolkit. It depends on the core; the core never depends on it.

  `call/2` is the visible chain [pipelines design reference "The visible
  chain"]: endpoint split → raw path extract → signature verify (403 before
  any option parsing) → option parse → `exp` gate (400) → geometry check →
  source translation/resolution → negotiate → build the representation
  identity (key/ETag/Vary) → conditional-GET gate → serve.

  ## Everything decidable from the request is decided before the fetch

  Parser and planner rejections return before any source fetch or cache
  access [AGENTS.md, request safety]. The signature, the option grammar, and
  the `exp` gate are self-evidently pre-fetch, but the geometry is not: a
  request whose pipelines cannot assemble an operation list (`rs:fill` with
  no dimensions, a `dpr` with no rational) is only discovered by
  `ImagePipe.Dialect.Imgproxy.Assembly.operations/1`, which
  `ImagePipe.Dialect.Imgproxy.Pipeline` reaches at run time — after the
  fetch and the decode. `check_geometry/1` therefore runs the same pure
  function over every pipeline ahead of the fetch, restoring the ordering
  the framework arm gets for free by assembling at parse time. The run-time
  call stays: it is the one that produces the operations, and re-running a
  pure function over a parsed request costs nothing next to a fetch.

  The conditional-GET gate (`Response.Conditional.not_modified?/2`) runs
  BEFORE `serve/7`'s cache lookup: the ETag is derived purely from pre-fetch
  request-identity material (`ImagePipe.Representation`), so a matching
  `If-None-Match` short-circuits to 304 without ever touching the cache or
  the source. `serve/7` calls `Cache.lookup_entry/2` and, on a hit, delivers
  the stored entry directly (re-checking `If-None-Match: *` at that point,
  per RFC 9110 §13.1.2); on a miss it falls through to `generate/7`.

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
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Decode,
      ImagePipe.Delivery,
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

  @behaviour Plug

  import Plug.Conn, only: [put_resp_content_type: 2, put_resp_header: 3, send_resp: 3]

  alias ImagePipe.Cache
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.Config
  alias ImagePipe.Dialect.Imgproxy.Errors
  alias ImagePipe.Dialect.Imgproxy.Identity
  alias ImagePipe.Dialect.Imgproxy.InfoRenderer
  alias ImagePipe.Dialect.Imgproxy.Negotiation
  alias ImagePipe.Dialect.Imgproxy.Options
  alias ImagePipe.Dialect.Imgproxy.Path
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Dialect.Imgproxy.ResponseMeta
  alias ImagePipe.Dialect.Imgproxy.Signature
  alias ImagePipe.Dialect.Imgproxy.Source, as: ImgproxySource
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias Vix.Vips.Image, as: VipsImage

  # The dialect collects no debug facts yet, so it hands `Delivery` nothing
  # for the `X-ImagePipe-*` headers or the cache entry's stored debug.
  @debug_info nil

  # `/info` has one fixed terminal: no format to select, and so nothing to vary
  # by or to carry as output-policy identity material.
  @info_negotiation %Negotiation{
    selected: {:terminal, :info},
    vary?: false,
    policy_material: [],
    policy: nil
  }

  # `/info` reads the header and nothing else, so it asks the decode planner for
  # no shrink at all: every field of a bare request is already the "no
  # preflight" answer.
  @info_decode_request %DecodePlanner.Request{}

  # Effective per-axis + pixel result caps for `Output.Clamp`, mirroring
  # `ImagePipe.Request.DeliveryBuild`'s own `effective_limits/2`: the tighter
  # of the host cap and the chosen encoder's hard limit. The framework arm
  # exposes the host half as `max_result_*` request options; this dialect's
  # config has no such keys yet, so the host half is fixed here at the
  # framework's own defaults.
  @default_max_result_width 8_192
  @default_max_result_height 8_192
  @default_max_result_pixels 40_000_000

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, config) when is_list(config) do
    Telemetry.Trace.maybe_extract_inbound(conn)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, config)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  defp route(%Plug.Conn{} = conn, config) do
    case Path.split_endpoint(conn) do
      {:info, info_conn} -> route_info(info_conn, config)
      :image -> route_image(conn, config)
    end
  end

  # The `[:request]` span's `:result` vocabulary [AGENTS.md, telemetry
  # guidelines]. `:ok`/`:not_modified` pass straight through; every `{:error,
  # reason}` this chain produces gets classified via `outcome_result/1` below.
  defp request_metadata(:ok), do: %{result: :ok}
  defp request_metadata(:not_modified), do: %{result: :not_modified}

  defp request_metadata({:error, reason}),
    do: %{result: outcome_result(reason), error: Error.tag(reason)}

  # This dialect's own client-reject reasons — the signature and `exp` gates,
  # both pre-fetch and pre-option-parse — get the framework's client-error
  # atom directly, the same way `ImagePipe.Plug`'s parser errors always render
  # `:parser_error` regardless of the underlying reason. `Assembly.operations/1`'s
  # geometry rejection is the one exception: `{:missing_dimensions, _}` is a
  # plan-shape failure (mirrors the framework's `PlanBuilder`-time geometry
  # check), not a syntax one, so it gets `:plan_error` even though `Errors.send/4`
  # answers it with the same 400 as every other parse reject.
  #
  # Everything else — Options/Path/Source translate rejects (`:unknown_option`,
  # `:invalid_option_segment`, `:invalid_source_url`, …), and the core-stage
  # reasons (`:source`, `:decode`, `:input_limit`, `:unsupported_output_format`,
  # `:encode`, `:session`, `:transform`) — defers to the shared classifier,
  # `ImagePipe.Telemetry.request_result/1`. That classifier already resolves
  # `{:source, _}` to `:source_error` for free; everything it does not
  # specifically recognize (including the long, open-ended tail of Options/Path
  # rejects) lands at its `:processing_error` default.
  defp outcome_result(:invalid_signature), do: :parser_error
  defp outcome_result({:invalid_signature_encoding, _signature}), do: :parser_error
  defp outcome_result({:unsupported_signature, _signature}), do: :parser_error
  defp outcome_result({:expired_request, _expires}), do: :parser_error
  defp outcome_result({:missing_dimensions, _resizing_type}), do: :plan_error
  defp outcome_result(reason), do: Telemetry.request_result({:error, reason})

  # The `/info` terminal [spec §The /info cache path]. Skips three of the image
  # chain's steps because the framework arm's own info plan does
  # (`PlanBuilder.to_plan/2`'s `info?: true` head builds `pipelines: []`,
  # `output: nil`, `response: %Response{}`): the geometry check has no
  # operations to reject, negotiation has no format to select, and there is no
  # image body to attach a `Content-Disposition` to. The `exp` gate and the
  # signature still apply.
  #
  # `request/5`'s `:info` head drops the parsed pipelines and output for the same
  # reason, so none of the three can reach this terminal's identity.
  #
  # The signature is verified over the path WITHOUT the `/info` prefix —
  # `split_endpoint/1` already handed back a prefix-stripped conn, and
  # `Path.extract/1` reads it — matching upstream. The chain never re-derives
  # the signed path.
  defp route_info(%Plug.Conn{} = conn, config) do
    with {:ok, request} <- parse(conn, config, :info),
         :ok <- check_expires(request, config),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config),
         {:ok, resolved} <- ImageSource.resolve(plan_source, config, config) do
      representation =
        Representation.build(
          resolved.identity,
          Identity.material(request, @info_negotiation, conn, config),
          resolved.cache_semantics.byte_identity
        )

      if Conditional.not_modified?(conn, representation.etag) do
        conn = Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
        {conn, request_metadata(:not_modified)}
      else
        serve_info(conn, resolved, representation, config)
      end
    else
      {:error, reason} ->
        conn = Errors.send(conn, reason, config)
        {conn, request_metadata({:error, reason})}
    end
  end

  defp route_image(%Plug.Conn{} = conn, config) do
    with {:ok, request} <- parse(conn, config, :image),
         :ok <- check_expires(request, config),
         :ok <- check_geometry(request),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config),
         {:ok, response_meta} <- ResponseMeta.build(request, plan_source),
         {:ok, resolved} <- ImageSource.resolve(plan_source, config, config),
         {:ok, negotiation} <- negotiate(conn, request, config) do
      representation =
        Representation.build(
          resolved.identity,
          Identity.material(request, negotiation, conn, config),
          resolved.cache_semantics.byte_identity
        )

      if Conditional.not_modified?(conn, representation.etag) do
        conn = Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
        {conn, request_metadata(:not_modified)}
      else
        serve(conn, request, resolved, negotiation, representation, response_meta, config)
      end
    else
      {:error, reason} ->
        conn = Errors.send(conn, reason, config)
        {conn, request_metadata({:error, reason})}
    end
  end

  # -- extract → verify → split → parse, one telemetry span ------------------

  # Ports `ImagePipe.Parser.Imgproxy.parse_image_request/2` + the output-format
  # merge of its `parsed_request/4`, reading the dialect's FLAT config where
  # the framework reads its `:imgproxy`-nested keyword.
  #
  # No `sig_key_index` stop metadata (native's `[:parse]` span carries one):
  # imgproxy's signature grammar has no key index to carry. `Signature.verify/3`
  # returns a bare `:ok` — it tries every configured key/salt pair with
  # `Enum.any?/2` and never reports which one matched, in this dialect's copy
  # and in the frozen framework original alike.
  defp parse(%Plug.Conn{} = conn, config, endpoint) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      result = parse_request(conn, config, endpoint)
      {result, parse_stop_metadata(result)}
    end)
  end

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

  # Ports `ImagePipe.Parser.Imgproxy.parse_info_request/2`'s struct: `info?`
  # set, `auto_rotate` forced off (the reported orientation is the source's own
  # header, so the decode must not consume it), and the output untouched by the
  # discarded source format.
  #
  # The parsed `pipelines` and `output` are DROPPED, mirroring
  # `PlanBuilder.to_plan/2`'s `info?: true` head (`pipelines: []`, `output:
  # nil`). /info never runs a pipeline and never encodes — `serve_info/4` goes
  # straight to `source_info/2` with `@info_decode_request` — so nothing on this
  # path reads either field except `Identity.material/4`. Carrying them meant
  # `/info/rs:fill:100:100/…` and `/info/…` got different cache keys and
  # different ETags for byte-identical bodies, forcing a client to re-download
  # identical content: exactly what the ETag's narrowness exists to prevent
  # (AGENTS.md). Dropping them here rather than teaching `Identity.material/4` to
  # ignore them for this terminal keeps the struct honest about what the request
  # will execute — an identity that folds in only what the struct carries cannot
  # regrow this bug when a field is added.
  #
  # `output` is not nilable on this struct (unlike the framework's `Plan`), so
  # the defaults — no format, no quality, no encoder options — are the spelling
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
  # This deliberately does NOT reproduce the framework's value, which is the
  # constant `:error` for every parse failure it can have: `ImagePipe.Plug`'s
  # `wrap_parser_error/1` re-wraps `{:error, reason}` as `{:error, {:parser,
  # {:error, reason}}}`, so `result_metadata/1`'s `Error.tag(error)` reads the
  # tag of `{:error, reason}` — the atom `:error` — and never reaches `reason`.
  # Observed on the framework arm for three unrelated failures (a missing
  # dimension, an invalid format, an unknown option): `%{error: :error}` each
  # time. Matching that would carry the quirk into a chain that does not share
  # the double-wrap, to emit a constant conveying nothing.
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

  # The geometry half of the framework arm's parse-time plan build, run here
  # for its rejection only — see the moduledoc. The operations themselves are
  # produced (again) by `Pipeline.run/4`, which owns the per-pipeline shape
  # the operations are assembled against.
  defp check_geometry(%Request{pipelines: pipelines}) do
    Enum.reduce_while(pipelines, :ok, fn pipeline_request, :ok ->
      case Assembly.operations(pipeline_request) do
        {:ok, _operations} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # -- negotiation ------------------------------------------------------------

  defp negotiate(%Plug.Conn{} = conn, %Request{} = request, config) do
    policy = Policy.from_output_plan(conn, Identity.plan_output(request), config)

    with :ok <- Policy.ensure_capable(policy, config) do
      {selected_format, vary?} = normalize_selection(Policy.identity_selection(policy))

      {:ok,
       %Negotiation{
         selected: {:image, selected_format},
         vary?: vary?,
         policy_material: Policy.identity_material(policy),
         policy: policy
       }}
    end
  end

  defp normalize_selection({:explicit, format}), do: {format, false}
  defp normalize_selection({:auto_head, format}), do: {format, true}
  defp normalize_selection(:source_negotiated), do: {:source_negotiated, true}

  # -- cache lookup + hit delivery / miss generate -----------------------------

  # A source that resolved `internal_cache: :disabled` has declared its bytes
  # must not be stored, so this skips the lookup AND the write — mirroring
  # `ImagePipe.Request.Runner.run_with_cache_config/5`, which pattern-matches the
  # same field and hands its `process_prepared_stream/6` a `nil` cache key.
  # `Delivery.stream/5` already documents `nil` as "no cache for this request".
  #
  # It is not only an opt-out to respect: `:disabled` is also what
  # `internal_cache: :auto` resolves to for a source whose bytes have no stable
  # identity, and keying a stored entry to bytes that cannot be identified is
  # unsound regardless of intent.
  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :disabled} = resolved,
         negotiation,
         representation,
         response_meta,
         config
       ) do
    generate(conn, request, resolved, negotiation, representation, response_meta, nil, config)
  end

  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :enabled} = resolved,
         negotiation,
         representation,
         response_meta,
         config
       ) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, entry, representation, response_meta, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          request,
          resolved,
          negotiation,
          representation,
          response_meta,
          representation.cache_key,
          config
        )
    end
  end

  # A cache hit is the proof, absent pre-fetch, that a current representation
  # exists for this key — so this is the only place `If-None-Match: *` may be
  # honored (mirroring `ImagePipe.Request.Runner`'s own hit-path check).
  defp deliver_hit(
         conn,
         %Cache.Entry{} = entry,
         %Representation{} = representation,
         %PlanResponse{} = response_meta,
         cache_serve_us,
         config
       ) do
    if Conditional.if_none_match_wildcard?(conn) do
      conn = Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
      {conn, request_metadata(:not_modified)}
    else
      hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}

      conn =
        Sender.send_result(
          conn,
          {:ok, {:cache_entry, entry, response_meta, cache_headers(representation), hit_debug}},
          config
        )

      {conn, request_metadata(:ok)}
    end
  end

  # `cache_key` is `nil` when the resolved source disabled the internal cache —
  # `Delivery.stream/5` then produces the response without opening a sink.
  defp generate(
         conn,
         request,
         %ImageSource.Resolved{} = resolved,
         %Negotiation{selected: {:image, _selected_format}} = negotiation,
         %Representation{} = representation,
         %PlanResponse{} = response_meta,
         cache_key,
         config
       ) do
    build_fun = build_fun(resolved, request, negotiation, config)

    case Delivery.stream(self(), build_fun, cache_key, response_meta, config) do
      {:ok, prepared} ->
        conn =
          Sender.send_result(
            conn,
            {:ok, {:prepared_stream, prepared, response_meta, cache_headers(representation)}},
            config
          )

        {conn, request_metadata(:ok)}

      # The negotiated policy's headers ride the failure, as they do on the
      # framework's own delivery errors (`Runner.process_prepared_stream/6` tags
      # `policy.headers` onto every `Delivery.stream/5` error): this response was
      # Accept-negotiated even though it failed.
      {:error, reason} ->
        conn = Errors.send(conn, reason, config, negotiation.policy.headers)
        {conn, request_metadata({:error, reason})}
    end
  end

  # -- /info: a complete body, not a stream -----------------------------------
  #
  # Fetch, decode-to-header, and render entirely inline (no producer process),
  # then respond with `send_resp/3` directly. `Sender`'s `{:rendered, _}` shape
  # would do its own Accept negotiation over renderer-supplied offers, which
  # this terminal does not have; and its image-entry delivery assumes an
  # encoder output (`Plan.Response.content_disposition/2` only knows the image
  # delivery content types and errors on anything else). So both the hit and
  # the miss path stay a dialect-owned send.

  # As on the image path, a source that disabled the internal cache is neither
  # read from nor written to. The framework arm never caches /info at all (its
  # `Runner.run/5` render head returns before any cache access), so this
  # dialect-owned cache has no parity source to mirror — but the reason the
  # image path honors the flag holds here unchanged: the stored JSON reports this
  # source's format/dimensions/orientation, so serving a stale one for bytes that
  # carry no stable identity is the same unsoundness, one indirection later.
  defp serve_info(
         conn,
         %ImageSource.Resolved{internal_cache: :disabled} = resolved,
         %Representation{} = representation,
         config
       ) do
    generate_info(conn, resolved, representation, nil, config)
  end

  defp serve_info(
         conn,
         %ImageSource.Resolved{internal_cache: :enabled} = resolved,
         %Representation{} = representation,
         config
       ) do
    case Cache.lookup_entry(representation.cache_key, config) do
      {:hit, %Cache.Entry{representation: {:complete_body, content_type}} = entry} ->
        deliver_info_hit(conn, content_type, entry.body, representation, config)

      # Anything else — a miss, a disabled cache, or an entry an adapter stored
      # without the `{:complete_body, _}` tag (`Cache.FileSystem` does not
      # persist it yet) — regenerates. An untagged entry is indistinguishable
      # from an image entry, and sending one here would answer /info with image
      # bytes.
      _miss_or_untagged ->
        generate_info(conn, resolved, representation, representation.cache_key, config)
    end
  end

  # As on the image path, a cache hit is the proof that a current representation
  # exists for this key, so it is the only place `If-None-Match: *` is honored.
  defp deliver_info_hit(conn, content_type, body, %Representation{} = representation, config) do
    if Conditional.if_none_match_wildcard?(conn) do
      conn = Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
      {conn, request_metadata(:not_modified)}
    else
      conn = send_complete_body(conn, content_type, body, representation)
      {conn, request_metadata(:ok)}
    end
  end

  # `cache_key` is `nil` when the resolved source disabled the internal cache, and
  # then the rendered body is sent without being stored.
  defp generate_info(conn, resolved, %Representation{} = representation, cache_key, config) do
    started_at = System.monotonic_time(:microsecond)

    case source_info(resolved, config) do
      {:ok, %SourceInfo{} = info} ->
        {content_type, body} = InfoRenderer.render(info)
        cost_us = System.monotonic_time(:microsecond) - started_at
        write_complete_body_cache(cache_key, content_type, body, cost_us, config)
        conn = send_complete_body(conn, content_type, body, representation)
        {conn, request_metadata(:ok)}

      {:error, reason} ->
        conn = Errors.send(conn, reason, config)
        {conn, request_metadata({:error, reason})}
    end
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

  defp write_complete_body_cache(nil = _cache_disabled, _content_type, _body, _cost_us, _config),
    do: :ok

  # Fail-open, like every cache write: the sink's own error handling aborts the
  # adapter sink synchronously on a failed write, after which further writes and
  # the commit no-op — so the pipe chain needs no error branch of its own.
  defp write_complete_body_cache(%Cache.Key{} = cache_key, content_type, body, cost_us, config) do
    cache_key
    |> Cache.open_sink({:complete_body, content_type}, Keyword.put(config, :cost_us, cost_us))
    |> Cache.write_chunk(IO.iodata_to_binary(body), config)
    |> Cache.commit_sink(config)

    :ok
  end

  # The ETag, the Vary, and the content type are rebuilt from the CURRENT
  # request's representation, never read back off a stored entry (beyond its
  # content type) [spec §The /info cache path].
  #
  # The Vary must be stamped here and not only on the 304 branch: this terminal
  # never varies by Accept (`@info_negotiation`), but a configured
  # `storage_inputs` header can select a different resolved source and so a
  # genuinely different body. It varies the key, `cache_headers/1` already puts it
  # on the 304, and a 200 that omitted it left the two responses inconsistent and
  # let a shared cache serve one tenant's /info to another.
  defp send_complete_body(conn, content_type, body, %Representation{} = representation) do
    conn
    |> put_resp_headers(vary_headers(representation.vary))
    |> put_resp_headers(Representation.response_headers(representation))
    |> put_resp_content_type(content_type)
    |> send_resp(200, body)
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end

  defp vary_headers([]), do: []
  defp vary_headers(names) when is_list(names), do: [{"vary", Enum.join(names, ", ")}]

  defp cache_headers(%Representation{} = representation) do
    %CacheHeaders{
      etag: representation.etag,
      representation_headers: vary_headers(representation.vary),
      headers: Representation.response_headers(representation)
    }
  end

  # -- build_fun: fetch → decode → transform → encode, run INSIDE the ----------
  # -- producer process, entirely inside Decode.with_image's bracket. ---------

  defp build_fun(%ImageSource.Resolved{} = resolved, %Request{} = request, negotiation, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, request.auto_rotate)
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      Decode.with_image(
        resolved,
        decode_opts,
        &Pipeline.decode_request(request, &1),
        fn state, geometry ->
          try do
            build_and_pump(state, geometry, request, negotiation, config, pump)
          after
            on_bracket_exit.()
          end
        end
      )
    end
  end

  defp build_and_pump(state, geometry, request, negotiation, config, pump) do
    with {:ok, state} <-
           Pipeline.run(
             state,
             geometry,
             request,
             pipeline_opts(negotiation, request, geometry, config)
           ),
         {:ok, resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp(state.image, result_limits(resolved_output.format), config),
         {:ok, stream, content_type, _search_meta} <-
           Encoder.stream_output(clamped, resolved_output, config) do
      pump.(stream, content_type, resolved_output, @debug_info)
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  # `Pipeline.run/4`'s input-color-management preamble needs to know whether the
  # HDR working space survives to the output, which is a fact about the
  # NEGOTIATED format, not about any operation. Mirrors
  # `ImagePipe.Request.DeliveryBuild`'s own threading of the same option
  # (`measure_transform/2`) — including its conservative `false` for the branch
  # where the format is only known after the transform.
  defp pipeline_opts(%Negotiation{policy: policy}, %Request{} = request, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(policy, Identity.plan_output(request), geometry.source_format)
    )
  end

  defp resolve_output(policy, source_format, image) do
    case Policy.resolve(policy, source_format) do
      {:ok, resolved_output} ->
        {:ok, resolved_output}

      {:needs_final_image_alpha, :source} ->
        {:ok, Policy.resolve_final_image_alpha(policy, Image.has_alpha?(image))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp result_limits(format) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      Encoder.encoder_limit(format)

    %{
      max_width: min_limit(@default_max_result_width, encoder_dimension),
      max_height: min_limit(@default_max_result_height, encoder_dimension),
      max_pixels: min_limit(@default_max_result_pixels, encoder_pixels)
    }
  end

  # Only the encoder limit can be `:infinity` ("no limit from the encoder").
  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)
end
