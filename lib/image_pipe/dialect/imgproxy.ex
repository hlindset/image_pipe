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

  alias ImagePipe.Cache
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Dialect.Imgproxy.Config
  alias ImagePipe.Dialect.Imgproxy.Errors
  alias ImagePipe.Dialect.Imgproxy.Identity
  alias ImagePipe.Dialect.Imgproxy.Negotiation
  alias ImagePipe.Dialect.Imgproxy.Options
  alias ImagePipe.Dialect.Imgproxy.Path
  alias ImagePipe.Dialect.Imgproxy.Pipeline
  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Dialect.Imgproxy.ResponseMeta
  alias ImagePipe.Dialect.Imgproxy.Signature
  alias ImagePipe.Dialect.Imgproxy.Source, as: ImgproxySource
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry

  # The dialect collects no debug facts yet, so it hands `Delivery` nothing
  # for the `X-ImagePipe-*` headers or the cache entry's stored debug.
  @debug_info nil

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
    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      conn = route(conn, config)
      {conn, %{status: conn.status}}
    end)
  end

  defp route(%Plug.Conn{} = conn, config) do
    case Path.split_endpoint(conn) do
      {:info, _info_conn} -> Errors.send(conn, :info_not_implemented, config)
      :image -> route_image(conn, config)
    end
  end

  defp route_image(%Plug.Conn{} = conn, config) do
    with {:ok, request} <- parse(conn, config),
         :ok <- check_expires(request, config),
         :ok <- check_geometry(request),
         {:ok, plan_source} <- ImgproxySource.translate(request.source_path, config),
         {:ok, response_meta} <- ResponseMeta.build(request, plan_source),
         {:ok, resolved} <- ImageSource.resolve(plan_source, config, config),
         {:ok, negotiation} <- negotiate(conn, request, config) do
      representation =
        Representation.build(
          resolved.identity,
          Identity.material(request, negotiation, conn, config)
        )

      if Conditional.not_modified?(conn, representation.etag) do
        Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
      else
        serve(conn, request, resolved, negotiation, representation, response_meta, config)
      end
    else
      {:error, reason} -> Errors.send(conn, reason, config)
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
  defp parse(%Plug.Conn{} = conn, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      result = parse_image_request(conn, config)
      {result, parse_stop_metadata(result)}
    end)
  end

  defp parse_image_request(%Plug.Conn{} = conn, config) do
    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- Signature.verify(signature, signed_path, Keyword.fetch!(config, :signature)),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <- parse_options(option_segments, config),
         {:ok, source_path, source_format} <-
           Path.parse_source(source_kind, raw_source_path, config) do
      {:ok, image_request(signature, source_path, source_format, request_options)}
    end
  end

  defp parse_options(option_segments, config),
    do: Options.parse(option_segments, Keyword.fetch!(config, :presets), config)

  defp image_request(signature, source_path, source_format, request_options) do
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

  defp parse_stop_metadata({:ok, %Request{}}), do: %{result: :ok}
  defp parse_stop_metadata({:error, _reason}), do: %{result: :error}

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

  defp serve(conn, request, resolved, negotiation, representation, response_meta, config) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, entry, representation, response_meta, cache_serve_us, config)

      _miss_or_disabled ->
        generate(conn, request, resolved, negotiation, representation, response_meta, config)
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
      Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
    else
      hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}

      Sender.send_result(
        conn,
        {:ok, {:cache_entry, entry, response_meta, cache_headers(representation), hit_debug}},
        config
      )
    end
  end

  defp generate(
         conn,
         request,
         %ImageSource.Resolved{} = resolved,
         %Negotiation{selected: {:image, _selected_format}} = negotiation,
         %Representation{} = representation,
         %PlanResponse{} = response_meta,
         config
       ) do
    build_fun = build_fun(resolved, request, negotiation, config)

    case Delivery.stream(self(), build_fun, representation.cache_key, response_meta, config) do
      {:ok, prepared} ->
        Sender.send_result(
          conn,
          {:ok, {:prepared_stream, prepared, response_meta, cache_headers(representation)}},
          config
        )

      {:error, reason} ->
        Errors.send(conn, reason, config)
    end
  end

  defp vary_headers([]), do: []
  defp vary_headers(names) when is_list(names), do: [{"vary", Enum.join(names, ", ")}]

  defp cache_headers(%Representation{} = representation) do
    %CacheHeaders{
      etag: representation.etag,
      representation_headers: vary_headers(representation.vary),
      headers: [{"etag", representation.etag}]
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
