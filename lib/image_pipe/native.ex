defmodule ImagePipe.Native do
  @moduledoc """
  ImagePipe's native URL API, mounted through `plug ImagePipe.Plug,
  sources: [...]`. Owns parsing (verify → lex → parse), expiry, source
  translation, representation identity, terminals, and error rendering.
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
    exports: [SourceScheme]

  alias ImagePipe.Decode
  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Errors
  alias ImagePipe.Native.Identity
  alias ImagePipe.Native.Info
  alias ImagePipe.Native.Output, as: NativeOutput
  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Path
  alias ImagePipe.Native.Signature
  alias ImagePipe.Native.Source, as: NativeSource
  alias ImagePipe.Native.SourceEncryption
  alias ImagePipe.Output.Terminal.Blurhash
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Executor

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

  def prepare(%Request{} = request, config) do
    with :ok <- check_expires(request, Keyword.fetch!(config, :clock).()),
         {:ok, plan_output} <- NativeOutput.resolve(request.output, config),
         :ok <- check_detector(request, config),
         {:ok, plan_source} <- NativeSource.translate(request.source, config) do
      {:ok, plan_source, plan_output}
    end
  end

  def identity_material(%Request{} = request, policy, conn, config) do
    Identity.material(request, policy, conn, config, detector_identity(request, config))
  end

  def render_terminal(source, %Request{} = request, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:output, :terminal],
      %{terminal: request.output.terminal},
      fn ->
        result = render_body(source, request, config)
        {result, %{result: terminal_result(result)}}
      end
    )
  end

  defp render_body(
         source,
         %Request{output: %Request.Output{terminal: :blurhash}} = request,
         config
       ) do
    case compute_blurhash(source, request, config) do
      {:ok, hash} -> {:ok, "text/plain", hash}
      {:error, _reason} = error -> error
    end
  end

  defp render_body(source, %Request{output: %Request.Output{terminal: :info}} = request, config) do
    Info.render_source(source, request, config)
  end

  def render_error(conn, reason), do: Errors.send(conn, reason)

  # Native client-reject reasons get the `:parser_error` client-error
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

  def response_meta(%Request{} = request) do
    %PlanResponse{
      filename: request.filename,
      disposition: if(request.attachment?, do: :attachment, else: :inline),
      debug?: request.debug?
    }
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
    Decode.with_image(
      resolved,
      request,
      config,
      fn state, _geometry -> run_blurhash(state, request, config) end
    )
  end

  defp run_blurhash(state, request, config) do
    with {:ok, state} <- Executor.execute(state, request, config),
         {:ok, state} <- Executor.reduce_terminal(state, request.output, config),
         {:ok, hash} <- Blurhash.compute(state.image) do
      {:ok, hash}
    else
      {:error, {:transform, _reason}} = error -> error
      # `Executor.execute/3` returns `{:decode, _}` too, from the input-colour
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
