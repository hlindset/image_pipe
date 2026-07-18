defmodule ImagePipe.Dialect.Native do
  @moduledoc """
  Plug entry point for ImagePipe's native URL dialect.

  Unlike `ImagePipe.Plug` (which dispatches through the framework's
  `Parser`/`Request`/`Resolver`/`Renderer` stack), this dialect owns its
  whole request chain end to end, assembled directly from ImagePipe's core
  toolkit. It depends on the core; the core never depends on it.

  `call/2` is the visible chain [pipelines design reference "The visible
  chain"]: raw byte split → verify (403 before any parsing) → full lex →
  parse → `expires` gate (404) → source translation/resolution → negotiate
  → build the representation identity (key/ETag/Vary) → conditional-GET gate
  → serve.

  The conditional-GET gate (`Response.Conditional.not_modified?/2`) runs
  BEFORE `serve/6`'s cache lookup: since the ETag is derived purely from
  pre-fetch request-identity material (`ImagePipe.Representation`), a
  matching `If-None-Match` short-circuits to 304 without ever touching the
  cache or the source — stricter and cheaper than the framework's own
  post-cache-lookup conditional evaluation. `serve/6` calls
  `Cache.lookup_entry/2` and, on a hit, delivers the stored entry directly
  (re-checking `If-None-Match: *` at that point, per RFC 9110 §13.1.2 — see
  `deliver_hit/4`); on a miss it falls through to `generate/6`.

  ## Mount prefix caveat

  `ImagePipe.Dialect.Native.Path` strips the mount prefix from the raw
  request path by treating `conn.script_name` (Plug's *decoded* segment
  list) as a byte-exact raw string prefix of `conn.request_path`. This is
  only correct when the mount path is canonical unescaped ASCII. A
  `script_name` segment that round-trips unequal through percent-encoding
  is host misconfiguration and raises at request runtime (500-class, never
  a client 400) — non-canonical/escaped mount paths are unsupported in v1.
  A config-supplied raw mount prefix is the future escape hatch.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
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
    exports: []

  @behaviour Plug

  import Plug.Conn, only: [put_resp_content_type: 3, put_resp_header: 3, send_resp: 3]

  alias ImagePipe.Cache
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Dialect.Native.Config
  alias ImagePipe.Dialect.Native.Errors
  alias ImagePipe.Dialect.Native.Identity
  alias ImagePipe.Dialect.Native.Negotiation
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Native.Path
  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Signature
  alias ImagePipe.Dialect.Native.Source, as: NativeSource
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  # The BlurHash terminal's delivery content type. Fixed — `format`/`q` with
  # a non-image `output` are Tier-2 parse rejects (Task 5), so no negotiation
  # or dialect config ever changes this.
  @blurhash_content_type "text/plain; charset=utf-8"

  # The probe subset collects no debug facts, so it hands `Delivery` nothing
  # for the `X-ImagePipe-*` headers or the cache entry's stored debug.
  @debug_info nil

  # The probe subset has no `orient` option — EXIF auto-orient is always on.
  # This is the dialect's own choice, per ImagePipe.Decode.with_image/4's
  # contract ("the EXIF policy is the CALLER's choice, never baked into this
  # core primitive").
  @auto_rotate? true

  @impl Plug
  # ex_dna:disable-for-next-line
  def init(opts), do: Config.validate!(opts)

  @impl Plug
  # ex_dna:disable-for-next-line
  def call(%Plug.Conn{} = conn, config) when is_list(config) do
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, config)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, config)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end

  # ex_dna:disable-for-next-line
  defp route(%Plug.Conn{method: "OPTIONS"} = conn, config) do
    conn = send_with_span(conn, config, :options, fn -> CORS.send_options(conn, config) end)
    {conn, %{result: :options}}
  end

  # ex_dna:disable-for-next-line
  defp route(%Plug.Conn{method: method} = conn, config) when method not in ["GET", "HEAD"] do
    conn =
      send_with_span(conn, config, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp route(%Plug.Conn{} = conn, config) do
    now = System.os_time(:second)

    with {:ok, request} <- parse(conn, config),
         :ok <- check_expires(request, now),
         {:ok, plan_source} <- NativeSource.translate(request.source, config),
         {:ok, resolved} <- ImageSource.resolve(plan_source, config, config),
         {:ok, negotiation} <- negotiate(conn, request, config) do
      representation =
        Representation.build(
          resolved.identity,
          Identity.material(request, negotiation, conn, config),
          resolved.cache_semantics.byte_identity
        )

      if Conditional.not_modified?(conn, representation.etag) do
        send_not_modified(conn, representation, config)
      else
        serve(conn, request, resolved, negotiation, representation, config)
      end
    else
      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  # The `[:send]` span, wrapping every terminal send this dialect performs —
  # `Sender.send_result/3`, `Errors.send/3`, the complete-body `send_resp/3`
  # sends (blurhash and its cache hit), and the OPTIONS-204/method-405 heads —
  # mirroring `ImagePipe.Plug.send_response/4` + `send_stop_metadata/2`.
  # `[:deliver]` (the shared `Response.Sender` streaming span) nests inside it;
  # both run in the connection-owner process.
  # ex_dna:disable-for-next-line
  defp send_with_span(%Plug.Conn{}, config, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:send], %{result: result}, fn ->
      sent_conn = fun.()
      {sent_conn, send_stop_metadata(sent_conn, result)}
    end)
  end

  defp send_stop_metadata(%Plug.Conn{} = conn, result) do
    %{
      result: Map.get(conn.private, :image_pipe_send_result, result),
      status: conn.status
    }
  end

  # The three send shapes every branch of this chain reduces to, each one a
  # `[:send]`-wrapped terminal paired with its `[:request]`-stop metadata.

  # ex_dna:disable-for-next-line
  defp send_not_modified(conn, %Representation{} = representation, config) do
    metadata = request_metadata(:not_modified)

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Sender.send_result(
          conn,
          {:not_modified, CacheHeaders.from_representation(representation)},
          config
        )
      end)

    {conn, metadata}
  end

  defp send_error(conn, reason, config) do
    metadata = request_metadata({:error, reason})

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Errors.send(conn, reason, config)
      end)

    {conn, metadata}
  end

  # The `[:request]` span's `:result` vocabulary [AGENTS.md, telemetry
  # guidelines]. `:ok`/`:not_modified` pass straight through; every `{:error,
  # reason}` this chain produces gets classified via `outcome_result/1` below.
  # ex_dna:disable-for-next-line
  defp request_metadata(:ok), do: %{result: :ok}
  defp request_metadata(:not_modified), do: %{result: :not_modified}

  defp request_metadata({:error, reason}),
    do: %{result: outcome_result(reason), error: Error.tag(reason)}

  # This dialect's own client-reject reasons get the framework's client-error
  # atom directly, the same way `ImagePipe.Plug`'s parser errors always render
  # `:parser_error` regardless of the underlying reason: the signature gate
  # (`:missing_signature`/`:invalid_signature`/`:signature_without_keys`), the
  # `expires` gate (`:expired`), and `Parser.parse/2`'s whole parse-failure
  # bucket, which always wraps as the single `{:invalid_request, _diagnostics}`
  # tag (`ImagePipe.Dialect.Native.Parser`).
  #
  # Everything else — `NativeSource.translate/2`'s `{:invalid_source, _}` and
  # the core-stage reasons (`:source`, `:decode`, `:input_limit`,
  # `:unsupported_output_format`, `:encode`, `:session`, `:transform`) — defers
  # to the shared classifier, `ImagePipe.Telemetry.request_result/1`. That
  # classifier already resolves `{:source, _}` to `:source_error` for free;
  # everything it does not specifically recognize (including
  # `{:invalid_source, _}`) lands at its `:processing_error` default.
  defp outcome_result(reason)
       when reason in [:missing_signature, :invalid_signature, :signature_without_keys],
       do: :parser_error

  defp outcome_result({:invalid_request, _diagnostics}), do: :parser_error
  defp outcome_result(:expired), do: :parser_error
  defp outcome_result(reason), do: Telemetry.request_result({:error, reason})

  # -- verify → lex → parse, one telemetry span -----------------------------

  defp parse(%Plug.Conn{} = conn, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      {sig, signed_path} = Path.split_signature(conn)

      result =
        with {:ok, key_index} <- Signature.verify(sig, signed_path, config),
             {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
             {:ok, request} <- Parser.parse(lexed, config) do
          {request, key_index}
        end

      {unwrap_parse_result(result), parse_stop_metadata(result)}
    end)
  end

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp unwrap_parse_result({%Request{} = request, _key_index}), do: {:ok, request}
  defp unwrap_parse_result({:error, _reason} = error), do: error

  defp parse_stop_metadata({%Request{}, key_index}),
    do: %{result: :ok, sig_key_index: key_index}

  defp parse_stop_metadata({:error, _reason}), do: %{result: :error}

  defp check_expires(%Request{expires: expires}, now) do
    if Signature.expired?(expires, now), do: {:error, :expired}, else: :ok
  end

  # -- negotiation ------------------------------------------------------------

  # Not `defp`/not exported from the Boundary — kept a plain module function
  # (rather than private) solely so a focused unit test can call it directly
  # to pin the one-%Policy{} continuity invariant (the same policy value
  # visible in `negotiation.policy_material` and in the `%Output.Resolved{}`
  # that later reaches the encoder) without going through the full HTTP
  # chain. Still dialect-internal: no other top-level boundary may call it.
  @doc false
  @spec negotiate(Plug.Conn.t(), Request.t(), keyword()) ::
          {:ok, Negotiation.t()} | {:error, {:unsupported_output_format, Policy.format()}}
  def negotiate(%Plug.Conn{}, %Request{output: %Request.Output{terminal: :blurhash}}, _config) do
    {:ok,
     %Negotiation{
       selected: {:terminal, :blurhash},
       vary?: false,
       policy_material: [],
       policy: nil
     }}
  end

  # ex_dna:disable-for-next-line
  def negotiate(%Plug.Conn{} = conn, %Request{} = request, config) do
    plan_output = Identity.plan_output(request)
    policy = Policy.from_output_plan(conn, plan_output, config)

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

  defp serve(conn, request, resolved, negotiation, representation, config) do
    start = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - start

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, entry, representation, cache_serve_us, config)

      _miss_or_disabled ->
        generate(conn, request, resolved, negotiation, representation, config)
    end
  end

  # A cache hit is the proof, absent pre-fetch, that a current representation
  # exists for this key — so this is the only place `If-None-Match: *` may be
  # honored (mirroring `ImagePipe.Request.Runner`'s own hit-path check).
  defp deliver_hit(
         conn,
         %Cache.Entry{} = entry,
         %Representation{} = representation,
         cache_serve_us,
         config
       ) do
    if Conditional.if_none_match_wildcard?(conn) do
      send_not_modified(conn, representation, config)
    else
      deliver_hit_entry(conn, entry, representation, cache_serve_us, config)
    end
  end

  # A `{:complete_body, content_type}` entry (e.g. a warmed BlurHash) is sent
  # as a plain complete body with its stored content type — it must NOT flow
  # through `Sender`'s image-entry delivery, which assumes an encoder output
  # (`Plan.Response.content_disposition/2` only knows the fixed image
  # delivery content types and errors on anything else).
  defp deliver_hit_entry(
         conn,
         %Cache.Entry{representation: {:complete_body, content_type}} = entry,
         %Representation{} = representation,
         _cache_serve_us,
         config
       ) do
    metadata = request_metadata(:ok)

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        send_complete_body(conn, content_type, entry.body, representation)
      end)

    {conn, metadata}
  end

  defp deliver_hit_entry(conn, %Cache.Entry{} = entry, representation, cache_serve_us, config) do
    hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}
    metadata = request_metadata(:ok)

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Sender.send_result(
          conn,
          {:ok,
           {:cache_entry, entry, %PlanResponse{},
            CacheHeaders.from_representation(representation), hit_debug}},
          config
        )
      end)

    {conn, metadata}
  end

  # ex_dna:disable-for-next-line
  defp generate(
         conn,
         request,
         %ImageSource.Resolved{} = resolved,
         %Negotiation{selected: {:image, _selected_format}} = negotiation,
         %Representation{} = representation,
         config
       ) do
    response_meta = %PlanResponse{}
    build_fun = build_fun(resolved, request, negotiation, config)

    case Delivery.stream(self(), build_fun, representation.cache_key, response_meta, config) do
      {:ok, prepared} ->
        metadata = request_metadata(:ok)

        conn =
          send_with_span(conn, config, metadata.result, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:prepared_stream, prepared, response_meta,
                CacheHeaders.from_representation(representation)}},
              config
            )
          end)

        {conn, metadata}

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  # BlurHash terminal delivery: a complete body, not a stream — fetch,
  # decode, transform, and reduce entirely inline (no producer process), then
  # respond with `send_resp/3` directly. `Sender`'s `{:rendered, _}` shape
  # does JSON negotiation, not a fit for a bare text body, so this stays
  # dialect-owned send, same as the cache-hit complete-body branch above.
  defp generate(
         conn,
         request,
         %ImageSource.Resolved{} = resolved,
         %Negotiation{selected: {:terminal, :blurhash}},
         %Representation{} = representation,
         config
       ) do
    fetch_started_at = System.monotonic_time(:microsecond)

    case compute_blurhash(resolved, request, config) do
      {:ok, hash} ->
        cost_us = System.monotonic_time(:microsecond) - fetch_started_at
        write_complete_body_cache(representation, hash, cost_us, config)
        metadata = request_metadata(:ok)

        conn =
          send_with_span(conn, config, metadata.result, fn ->
            send_complete_body(conn, @blurhash_content_type, hash, representation)
          end)

        {conn, metadata}

      {:error, reason} ->
        send_error(conn, reason, config)
    end
  end

  defp compute_blurhash(%ImageSource.Resolved{} = resolved, %Request{} = request, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, @auto_rotate?)

    Decode.with_image(
      resolved,
      decode_opts,
      &Pipeline.decode_request(request, &1),
      fn state, geometry -> run_blurhash(state, geometry, request, config) end
    )
  end

  defp run_blurhash(state, geometry, request, config) do
    with {:ok, state} <- Pipeline.run(state, geometry, request, config),
         {:ok, state} <- Pipeline.reduce_terminal(state, request, config),
         {:ok, hash} <- Blurhash.compute(state.image) do
      {:ok, hash}
    else
      {:error, {:transform, _reason}} = error -> error
      # `Pipeline.run/4` returns `{:decode, _}` too, from the input-colour
      # preamble. It must reach `Errors.send/3` untouched: a malformed embedded
      # profile is a decode failure (415), and rewrapping it below would make
      # the same source 415 from the image terminal and 422 from this one.
      {:error, {:decode, _reason}} = error -> error
      {:error, reason} -> {:error, {:transform, {:blurhash_encode, reason}}}
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  defp send_complete_body(conn, content_type, body, %Representation{} = representation) do
    cache_headers = CacheHeaders.from_representation(representation)

    conn
    |> put_resp_headers(cache_headers.representation_headers)
    |> put_resp_headers(cache_headers.headers)
    |> put_resp_content_type(content_type, nil)
    |> send_resp(200, body)
  end

  defp write_complete_body_cache(%Representation{} = representation, hash, cost_us, config) do
    representation.cache_key
    |> Cache.open_sink(
      {:complete_body, @blurhash_content_type},
      Keyword.put(config, :cost_us, cost_us)
    )
    |> Cache.write_chunk(hash, config)
    |> Cache.commit_sink(config)

    :ok
  end

  defp put_resp_headers(conn, headers) do
    Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)
  end

  # -- build_fun: fetch → decode → transform → encode, run INSIDE the ----------
  # -- producer process, entirely inside Decode.with_image's bracket. ---------

  defp build_fun(%ImageSource.Resolved{} = resolved, %Request{} = request, negotiation, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, @auto_rotate?)
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

  # ex_dna:disable-for-next-line
  defp build_and_pump(state, geometry, request, negotiation, config, pump) do
    with {:ok, %State{} = state} <- run_transform(state, geometry, request, negotiation, config),
         {:ok, resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image, config),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             config
           ),
         {:ok, %State{image: image}} <-
           materialize_for_delivery(%State{state | image: clamped}, config),
         {:ok, chunk, content_type, stream_state, _search_meta} <-
           encode_first_chunk(image, resolved_output, config) do
      pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, @debug_info)
    else
      :empty -> {:error, {:encode, :empty_stream}}
      {:error, _reason} = error -> error
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  # The `[:transform, :execute]` span, wrapping the full pipeline run with the
  # framework's own start/stop shapes (`Request.Processor.process_decoded_source/3`
  # + `transform_stop_metadata/1`): start carries the aggregate semantic-plan
  # view (`operations`/`operation_count`), stop the `:result`.
  # ex_dna:disable-for-next-line
  defp run_transform(state, geometry, %Request{} = request, negotiation, config) do
    operations = Pipeline.operation_names(request)

    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: operations, operation_count: length(operations)},
      fn ->
        result =
          Pipeline.run(
            state,
            geometry,
            request,
            pipeline_opts(negotiation, request, geometry, config)
          )

        {result, transform_stop_metadata(result)}
      end
    )
  end

  # ex_dna:disable-for-next-line
  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  # The `[:encode]` span, mirroring the framework's honest forced-encode span
  # (`Request.DeliveryBuild.encode_first_chunk/3` + `first_chunk/1`):
  # `Encoder.stream_output/3` only builds the lazy encoder pipeline, so the
  # first chunk is pulled HERE, inside the span and inside the producer — not
  # later in the delivery pump, which would leave the span timing only encoder
  # construction. `StreamPull.resume/2` then hands `pump` an enumerable that
  # replays it. This is also what surfaces a first-chunk encode failure as a
  # pre-header 500 (the framework's behavior) instead of a mid-stream abort of
  # an already-committed 200.
  # ex_dna:disable-for-next-line
  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, config),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  # ex_dna:disable-for-next-line
  defp first_chunk(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  # ex_dna:disable-for-next-line
  defp encode_stop_metadata({:ok, _chunk, _content_type, _stream_state, _search_meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  # Delivery backstop, mirroring the framework's post-clamp barrier
  # (`ImagePipe.Request.Processor.materialize_for_delivery/2`): the build path has
  # no discretionary op that forces a mid-pipeline materialize, so a lazy vips
  # pipeline can reach the encoder unmaterialized. Copy to RAM once before encode
  # unless an op already did, mapping a copy failure to a decode error (→ 415) via
  # `Materializer.materialize/2`. The `[:transform, :materialize]` span comes for
  # free from `Materializer`. The carry stamp is NOT re-applied — `Pipeline.run/4`'s
  # tail already stamped it, so this half of the framework barrier is not duplicated.
  # ex_dna:disable-for-next-line
  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    case Materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # `Pipeline.run/4`'s input-color-management preamble needs to know whether the
  # HDR working space survives to the output, which is a fact about the
  # NEGOTIATED format, not about any operation. Mirrors
  # `ImagePipe.Dialect.Imgproxy`'s threading of the same option — including its
  # conservative `false` for the branch where the format is only known after the
  # transform. The blurhash terminal has no negotiated image format and does not
  # thread this, taking the same conservative default.
  # ex_dna:disable-for-next-line
  defp pipeline_opts(%Negotiation{policy: policy}, %Request{} = request, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(policy, Identity.plan_output(request), geometry.source_format)
    )
  end

  # Negotiation runs through the shared `Output.Negotiate` seam (the
  # `[:output, :negotiate]` span emitter). The helper's unwrapped `{:error,
  # reason}` is passed straight through, preserving this dialect's error shape.
  defp resolve_output(policy, source_format, image, config) do
    Negotiate.negotiate_output(
      policy,
      source_format,
      fn -> Image.has_alpha?(image) end,
      Telemetry.telemetry_opts(config)
    )
  end

  # ex_dna:disable-for-next-line
  defp result_limits(format, config) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
      max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
      max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
    }
  end

  # Only the encoder limit can be `:infinity` ("no limit from the encoder").
  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)
end
