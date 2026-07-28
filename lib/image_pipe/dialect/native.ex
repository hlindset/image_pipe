defmodule ImagePipe.Dialect.Native do
  @moduledoc """
  ImagePipe's native URL dialect, implemented as an `ImagePipe.Dialect` —
  mounted through `plug ImagePipe.Plug, dialect: ImagePipe.Dialect.Native,
  <flat config>`. The dialect owns parsing (verify → lex → parse), the
  `expires` gate, source translation, negotiation input, pipeline execution,
  and error rendering; the shared runner in `ImagePipe.Plug` owns the
  request lifecycle around them.

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
    exports: []

  @behaviour ImagePipe.Dialect

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Native.Config
  alias ImagePipe.Dialect.Native.Errors
  alias ImagePipe.Dialect.Native.Identity
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Native.Path
  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Signature
  alias ImagePipe.Dialect.Native.Source, as: NativeSource
  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry

  # The BlurHash terminal's delivery content type. Fixed — `format`/`q` with
  # a non-image `output` are Tier-2 parse rejects (Task 5), so no negotiation
  # or dialect config ever changes this.
  @blurhash_content_type "text/plain; charset=utf-8"

  # The probe subset has no `orient` option — EXIF auto-orient is always on.
  # This is the dialect's own choice, per ImagePipe.Decode.with_image/4's
  # contract ("the EXIF policy is the CALLER's choice, never baked into this
  # core primitive").
  @auto_rotate? true

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    {sig, signed_path} = Path.split_signature(conn)

    result =
      with {:ok, key_index} <- Signature.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
           {:ok, request} <- Parser.parse(lexed, config) do
        {request, key_index}
      end

    case result do
      {%Request{} = request, key_index} ->
        {{:ok, request}, %{result: :ok, sig_key_index: key_index}}

      {:error, _reason} = error ->
        # Deliberately NO error tag — preserving the chain's parse stop shape.
        {error, %{result: :error}}
    end
  end

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    # The clock read moves from route-entry (pre-parse) to here (post-parse):
    # only a sub-second expiry edge differs and nothing pins it.
    with :ok <- check_expires(request, System.os_time(:second)),
         {:ok, plan_source} <- NativeSource.translate(request.source, config) do
      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation: negotiation_result(conn, request, config),
         response_meta: %PlanResponse{},
         operations: Pipeline.operation_names(request),
         auto_rotate?: @auto_rotate?,
         debug?: false,
         terminal: terminal(request, config)
       }}
    end
  end

  defp negotiation_result(
         conn,
         %Request{output: %Request.Output{terminal: :blurhash}} = request,
         config
       ) do
    negotiation = DialectNegotiation.terminal(:blurhash)
    {:ok, negotiation, Identity.material(request, negotiation, conn, config)}
  end

  defp negotiation_result(conn, %Request{} = request, config) do
    case DialectNegotiation.negotiate(conn, Identity.plan_output(request), config) do
      {:ok, negotiation} ->
        {:ok, negotiation, Identity.material(request, negotiation, conn, config)}

      {:error, _reason} = error ->
        error
    end
  end

  defp terminal(%Request{output: %Request.Output{terminal: :blurhash}} = request, _config) do
    {:render,
     %RenderTerminal{
       fun: fn resolved_source, config ->
         case compute_blurhash(resolved_source, request, config) do
           {:ok, hash} -> {:ok, @blurhash_content_type, hash}
           {:error, _reason} = error -> error
         end
       end
     }}
  end

  defp terminal(_request, _config), do: :image

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

  # This dialect's own client-reject reasons get the framework's client-error
  # atom directly: the signature gate
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
  @impl ImagePipe.Dialect
  def classify_error(reason)
      when reason in [:missing_signature, :invalid_signature, :signature_without_keys],
      do: :parser_error

  def classify_error({:invalid_request, _diagnostics}), do: :parser_error
  def classify_error(:expired), do: :parser_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp check_expires(%Request{expires: expires}, now) do
    if Signature.expired?(expires, now), do: {:error, :expired}, else: :ok
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
end
