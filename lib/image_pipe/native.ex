defmodule ImagePipe.Native do
  @moduledoc """
  ImagePipe's native URL API, mounted through `plug ImagePipe.Plug,
  sources: [...]`. Owns parsing (verify → lex → parse), expiry, source
  translation, negotiation input, pipeline execution, and error rendering.
  `ImagePipe.Plug` orchestrates the request lifecycle.

  ## Mount prefix caveat

  `ImagePipe.Native.Path` strips the mount prefix from the raw
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
  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Errors
  alias ImagePipe.Native.Identity
  alias ImagePipe.Native.Info
  alias ImagePipe.Native.Output, as: NativeOutput
  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Path
  alias ImagePipe.Native.Pipeline
  alias ImagePipe.Native.Request
  alias ImagePipe.Native.Signature
  alias ImagePipe.Native.Source, as: NativeSource
  alias ImagePipe.Native.SourceEncryption
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  # The BlurHash terminal's delivery content type. Fixed — `format`/`q` with
  # a non-image `output` are Tier-2 parse rejects (Task 5), so no negotiation
  # or dialect config ever changes this.
  @blurhash_content_type "text/plain"

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @doc """
  Encrypts a UTF-8 source using a validated native mount configuration.

  The returned value is the token only. The host places it after the `enc/`
  source marker and signs the complete native request path.
  """
  @spec encrypt_source(term(), keyword()) ::
          {:ok, String.t()} | {:error, :invalid_source | :source_encryption_disabled}
  def encrypt_source(source, config) do
    SourceEncryption.encrypt(source, Keyword.fetch!(config, :source_encryption))
  end

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    {sig, signed_path} = Path.split_signature(conn)

    result =
      with {:ok, key_index} <- Signature.verify(sig, signed_path, config),
           {:ok, lexed} <- Path.extract(conn) |> normalize_lex_error(),
           {:ok, lexed} <- decrypt_source(lexed, config),
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
    with :ok <- check_expires(request, Keyword.fetch!(config, :clock).()),
         {:ok, plan_output} <- NativeOutput.resolve(request.output, config),
         :ok <- check_detector(request, config),
         {:ok, plan_source} <- NativeSource.translate(request.source, config) do
      {:ok,
       %Resolved{
         request: request,
         source: plan_source,
         negotiation: fn -> negotiation_result(conn, request, plan_output, config) end,
         response_meta: response_meta(request),
         operations: operation_names(request),
         auto_rotate?: auto_rotate?(request),
         debug?: request.debug?,
         http_cache:
           if(Keyword.has_key?(config, :http_cache), do: :generated, else: :dialect_owned),
         terminal: terminal(request, config)
       }}
    end
  end

  defp negotiation_result(
         conn,
         %Request{output: %Request.Output{terminal: terminal}} = request,
         _plan_output,
         config
       )
       when terminal in [:blurhash, :info] do
    negotiation = DialectNegotiation.terminal(terminal)

    detector_identity =
      if terminal == :blurhash, do: detector_identity(request, config), else: nil

    {:ok, negotiation, Identity.material(request, negotiation, conn, config, detector_identity)}
  end

  defp negotiation_result(conn, %Request{} = request, plan_output, config) do
    case DialectNegotiation.negotiate(conn, plan_output, config) do
      {:ok, negotiation} ->
        {:ok, negotiation,
         Identity.material(request, negotiation, conn, config, detector_identity(request, config))}

      {:error, _reason} = error ->
        error
    end
  end

  defp terminal(%Request{output: %Request.Output{terminal: :blurhash}} = request, _config) do
    {:render,
     %RenderTerminal{
       charset: :default,
       fun: fn resolved_source, config ->
         render_terminal(:blurhash, config, fn ->
           case compute_blurhash(resolved_source, request, config) do
             {:ok, hash} -> {:ok, @blurhash_content_type, hash}
             {:error, _reason} = error -> error
           end
         end)
       end
     }}
  end

  defp terminal(%Request{output: %Request.Output{terminal: :info}}, _config) do
    {:render,
     %RenderTerminal{
       charset: :default,
       fun: fn resolved_source, config ->
         render_terminal(:info, config, fn -> Info.render_source(resolved_source, config) end)
       end
     }}
  end

  defp terminal(_request, _config), do: :image

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry),
    do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  # The hand-written dialects' contract delegations are textually identical but
  # resolve through per-dialect aliases to different Request structs and
  # Pipeline modules — irreducible without a macro that would force a
  # naming convention on every dialect and hide the contract.
  # ex_dna:disable-for-next-line
  def execute(state, geometry, %Request{} = request, opts) do
    ImagePipe.Dialect.safe_transform(fn -> Pipeline.run(state, geometry, request, opts) end)
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  # This dialect's own client-reject reasons get the `:parser_error` client-error
  # atom directly: the signature gate
  # (`:missing_signature`/`:invalid_signature`/`:signature_without_keys`), the
  # `expires` gate (`:expired`), and `Parser.parse/2`'s whole parse-failure
  # bucket, which always wraps as the single `{:invalid_request, _diagnostics}`
  # tag (`ImagePipe.Native.Parser`).
  #
  # The strict detector capability gate and resolved output-policy failures are
  # plan errors. Everything else —
  # `NativeSource.translate/2`'s `{:invalid_source, _}` and the core-stage
  # reasons (`:source`, `:decode`, `:input_limit`,
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
  def classify_error(:invalid_concealed_source), do: :parser_error
  def classify_error(:expired), do: :parser_error
  def classify_error({:detector, :unavailable}), do: :plan_error
  def classify_error({:invalid_output, _reason}), do: :plan_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})

  defp normalize_lex_error({:error, diagnostics}), do: {:error, {:invalid_request, diagnostics}}
  defp normalize_lex_error({:ok, _lexed} = ok), do: ok

  defp decrypt_source(%{source: {:enc, token, span}} = lexed, config) do
    case SourceEncryption.decrypt(token, Keyword.fetch!(config, :source_encryption)) do
      {:ok, source} -> {:ok, %{lexed | source: {:enc, source, span}}}
      {:error, :invalid_concealed_source} = error -> error
    end
  end

  defp decrypt_source(lexed, _config), do: {:ok, lexed}

  defp check_expires(%Request{expires: expires}, now) do
    if Signature.expired?(expires, now), do: {:error, :expired}, else: :ok
  end

  defp response_meta(%Request{} = request) do
    %PlanResponse{
      filename: request.filename,
      disposition: if(request.attachment?, do: :attachment, else: :inline),
      debug?: request.debug?
    }
  end

  defp operation_names(%Request{output: %Request.Output{terminal: :info}}), do: []
  defp operation_names(%Request{} = request), do: Pipeline.operation_names(request)

  defp auto_rotate?(%Request{output: %Request.Output{terminal: :info}}), do: false
  defp auto_rotate?(%Request{} = request), do: request.orient == :auto

  defp render_terminal(name, config, fun) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:output, :terminal],
      %{terminal: name},
      fn ->
        result = fun.()
        {result, %{result: terminal_result(result)}}
      end
    )
  end

  defp terminal_result({:ok, _content_type, _body}), do: :ok
  defp terminal_result({:error, reason}), do: Telemetry.request_result({:error, reason})

  defp check_detector(%Request{} = request, config) do
    case explicit_detector_classes(request) do
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

  defp detector_identity(%Request{} = request, config) do
    case identity_detector_classes(request) do
      nil ->
        nil

      classes ->
        Transform.detector_identity(
          Keyword.get(config, :detector, :default),
          Keyword.put(config, :classes, classes)
        )
    end
  end

  defp identity_detector_classes(%Request{} = request) do
    case {explicit_detector_classes(request), face_assist?(request)} do
      {:all, _face_assist?} -> :all
      {nil, false} -> nil
      {nil, true} -> ["face"]
      {classes, false} -> classes
      {classes, true} -> Enum.sort(Enum.uniq(["face" | classes]))
    end
  end

  defp explicit_detector_classes(%Request{groups: groups}) do
    groups
    |> Enum.reduce_while([], fn group, classes ->
      case group.guide do
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {requested, _weights}} -> {:cont, requested ++ classes}
        _other -> {:cont, classes}
      end
    end)
    |> case do
      :all -> :all
      [] -> nil
      classes -> classes |> Enum.uniq() |> Enum.sort()
    end
  end

  defp face_assist?(%Request{groups: groups}) do
    Enum.any?(groups, &(&1.guide == {:smart, :face_assist}))
  end

  defp compute_blurhash(%ImageSource.Resolved{} = resolved, %Request{} = request, config) do
    decode_opts = Keyword.put(config, :auto_rotate?, request.orient == :auto)

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
