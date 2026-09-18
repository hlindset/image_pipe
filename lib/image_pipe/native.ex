defmodule ImagePipe.Native do
  @moduledoc """
  ImagePipe's URL API, mounted through `plug ImagePipe.Plug,
  sources: [...]`. Owns parsing (verify → lex → parse), expiry, source
  translation, representation identity, and error rendering.
  `ImagePipe.Plug` orchestrates the request lifecycle.

  ## Mount prefix caveat

  `ImagePipe.Native.Path` strips `conn.script_name` from `conn.request_path`
  as a raw prefix. Because Plug decodes `script_name`, mount paths must use
  canonical unescaped ASCII. A segment that changes when percent-encoded
  raises at request time as host misconfiguration (500-class).
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
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

  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Errors
  alias ImagePipe.Native.Identity
  alias ImagePipe.Native.Output, as: NativeOutput
  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Path
  alias ImagePipe.Native.Signature
  alias ImagePipe.Native.Source, as: NativeSource
  alias ImagePipe.Native.SourceEncryption
  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  def validate_config!(opts), do: Config.validate!(opts)

  @doc """
  Encrypts a UTF-8 source using a validated mount configuration.

  The returned value is the token only. The host places it after the `enc/`
  source marker and signs the complete request path.
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

  def prepare(%Request{} = request, config, accept_header) do
    with :ok <- check_expires(request, Keyword.fetch!(config, :clock).()),
         {:ok, policy} <- NativeOutput.resolve(request.output, config, accept_header),
         :ok <- ensure_output_capable(policy, config),
         :ok <- check_detector(request, config),
         {:ok, plan_source} <- NativeSource.translate(request.source, config) do
      {:ok, plan_source, policy}
    end
  end

  defp ensure_output_capable(nil, _config), do: :ok
  defp ensure_output_capable(policy, config), do: Policy.ensure_capable(policy, config)

  def identity_material(%Request{} = request, policy, conn, config) do
    Identity.material(request, policy, conn, config, detector_identity(request, config))
  end

  def render_error(conn, reason), do: Errors.send(conn, reason)

  # Client-reject reasons get the `:parser_error` client-error
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
end
