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
  → build the representation identity (key/ETag/Vary) → serve.

  This task (pipeline assembly) wires every request as a generate/stream
  MISS with a cache write — `serve/6` calls `Cache.lookup_entry/2` (so the
  telemetry/ordering contract is real) but does not yet special-case a hit;
  conditional-GET short-circuiting and cache-hit delivery land in a later
  task.

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

  alias ImagePipe.Cache
  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Native.Config
  alias ImagePipe.Dialect.Native.Delivery
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
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry

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

      serve(conn, request, resolved, negotiation, representation, config)
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

  # -- cache lookup (miss-shaped in this task) + generate ----------------------

  defp serve(conn, request, resolved, negotiation, representation, config) do
    case Cache.lookup_entry(representation.cache_key, config) do
      {:hit, _entry} ->
        # Cache-hit delivery (serving the stored entry directly, with
        # conditional-GET re-evaluation) is a later task's scope; every
        # request currently generates + writes, even on a hit.
        generate(conn, request, resolved, negotiation, representation, config)

      _miss_or_disabled ->
        generate(conn, request, resolved, negotiation, representation, config)
    end
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

    case Delivery.stream(self(), build_fun, representation, response_meta, config) do
      {:ok, prepared} ->
        cache_headers = %CacheHeaders{
          etag: representation.etag,
          representation_headers: vary_headers(representation.vary),
          headers: [{"etag", representation.etag}]
        }

        Sender.send_result(
          conn,
          {:ok, {:prepared_stream, prepared, response_meta, cache_headers}},
          config
        )

      {:error, reason} ->
        Errors.send(conn, reason, config)
    end
  end

  defp generate(
         conn,
         _request,
         _resolved,
         %Negotiation{selected: {:terminal, :blurhash}},
         _representation,
         config
       ) do
    # BlurHash terminal delivery lands in a later task.
    Errors.send(conn, {:unimplemented, :blurhash_terminal}, config)
  end

  defp vary_headers([]), do: []
  defp vary_headers(names) when is_list(names), do: [{"vary", Enum.join(names, ", ")}]

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
      pump.(stream, content_type, resolved_output)
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
