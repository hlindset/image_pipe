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
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry

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

  # Effective result-dimension/pixel caps for Output.Clamp. The framework's
  # equivalent (ImagePipe.Request.Options) exposes these as host-configurable
  # options; the probe subset does not (Native.Config has no max_result_*
  # keys yet), so they're fixed here at the framework's own defaults.
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
    now = System.os_time(:second)

    with {:ok, request} <- parse(conn, config),
         :ok <- check_expires(request, now),
         {:ok, plan_source} <- NativeSource.translate(request.source, config),
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
        serve(conn, request, resolved, negotiation, representation, config)
      end
    else
      {:error, reason} -> Errors.send(conn, reason, config)
    end
  end

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
      Sender.send_result(conn, {:not_modified, cache_headers(representation)}, config)
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
         _config
       ) do
    conn
    |> put_resp_header("etag", representation.etag)
    |> put_resp_content_type(content_type, nil)
    |> send_resp(200, entry.body)
  end

  defp deliver_hit_entry(conn, %Cache.Entry{} = entry, representation, cache_serve_us, config) do
    hit_debug = %{cache_key: representation.cache_key.hash, cache_serve_us: cache_serve_us}

    Sender.send_result(
      conn,
      {:ok, {:cache_entry, entry, %PlanResponse{}, cache_headers(representation), hit_debug}},
      config
    )
  end

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
        Sender.send_result(
          conn,
          {:ok, {:prepared_stream, prepared, response_meta, cache_headers(representation)}},
          config
        )

      {:error, reason} ->
        Errors.send(conn, reason, config)
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
        send_complete_body(conn, hash, representation)

      {:error, reason} ->
        Errors.send(conn, reason, config)
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
      {:error, reason} -> {:error, {:transform, {:blurhash_encode, reason}}}
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  defp send_complete_body(conn, hash, %Representation{} = representation) do
    conn
    |> put_resp_header("etag", representation.etag)
    |> put_resp_content_type(@blurhash_content_type, nil)
    |> send_resp(200, hash)
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

  defp build_and_pump(state, geometry, request, negotiation, config, pump) do
    with {:ok, state} <- Pipeline.run(state, geometry, request, config),
         {:ok, resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image),
         {:ok, clamped, _clamp_info} <- Clamp.clamp(state.image, result_limits(), config),
         {:ok, stream, content_type, _search_meta} <-
           Encoder.stream_output(clamped, resolved_output, config) do
      pump.(stream, content_type, resolved_output, @debug_info)
    end
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
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

  defp result_limits do
    %{
      max_width: @default_max_result_width,
      max_height: @default_max_result_height,
      max_pixels: @default_max_result_pixels
    }
  end
end
