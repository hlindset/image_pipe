defmodule ImagePipe.Parser.Imgproxy do
  @moduledoc """
  Parser for ImagePipe's imgproxy path-oriented URL syntax.
  """

  use Boundary,
    deps: [
      ImagePipe.Format,
      ImagePipe.Parser,
      ImagePipe.Plan,
      ImagePipe.Renderer
    ],
    exports: [
      SourceScheme
    ]

  @behaviour ImagePipe.Parser

  alias ImagePipe.Parser.Imgproxy.Options
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.Path
  alias ImagePipe.Parser.Imgproxy.PlanBuilder
  alias ImagePipe.Parser.Imgproxy.Presets
  alias ImagePipe.Parser.Imgproxy.Signature
  alias ImagePipe.Parser.Imgproxy.SourceEncryption

  # Dialect-only config. The product-neutral plan/output tunables (quality,
  # format_quality, strip_metadata, autoquality_*, jpeg_options/.../jxl_options, …) live in
  # `ImagePipe.Config`; this adapter validates only its dialect keys and delegates
  # the neutral keys to `Config.resolve!/2`.
  @dialect_schema NimbleOptions.new!(
                    signature: [type: :keyword_list, required: false],
                    source_url_encryption_key: [
                      type: {:custom, SourceEncryption, :validate_key, []},
                      required: false
                    ],
                    base64_url_includes_filename: [
                      type: :boolean,
                      default: false
                    ],
                    source_schemes: [
                      type: {:custom, __MODULE__, :validate_source_schemes, []},
                      default: %{}
                    ],
                    presets: [
                      type: {:custom, Presets, :validate_config, []},
                      default: %{}
                    ]
                  )

  @dialect_keys [
    :signature,
    :source_url_encryption_key,
    :base64_url_includes_filename,
    :source_schemes,
    :presets
  ]

  # Sparse parity overrides applied on top of the neutral defaults. EMPTY today
  # ("imgproxy parity == neutral defaults"); `jxl_options: %JxlOptions{effort: 4}`
  # is the documented future byte-parity lever, intentionally not set here.
  defp imgproxy_overlay, do: []

  def parse(%Plug.Conn{} = conn), do: parse(conn, [])

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

  @impl ImagePipe.Parser
  def validate_options!(opts) when is_list(opts) do
    imgproxy_opts =
      opts
      |> Keyword.get(:imgproxy, [])
      |> validate_imgproxy_options!()

    Keyword.put(opts, :imgproxy, imgproxy_opts)
  end

  defp validate_imgproxy_options!(imgproxy_opts) when is_list(imgproxy_opts) do
    {neutral, rest} = Keyword.split(imgproxy_opts, ImagePipe.Config.keys())
    {dialect, unknown} = Keyword.split(rest, @dialect_keys)

    unless unknown == [] do
      raise ArgumentError,
            "invalid imgproxy config: unknown keys #{inspect(Keyword.keys(unknown))}"
    end

    dialect = validate_dialect!(dialect)
    neutral = ImagePipe.Config.resolve!(neutral, imgproxy_overlay())

    Keyword.merge(neutral, dialect)
  end

  defp validate_imgproxy_options!(_imgproxy_opts),
    do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

  defp validate_dialect!(dialect) do
    case NimbleOptions.validate(dialect, @dialect_schema) do
      {:ok, validated} ->
        validated
        |> Keyword.update(:signature, Signature.disabled(), &Signature.normalize_config!/1)
        |> normalize_source_encryption()

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
    end
  end

  @doc false
  def validate_source_schemes(%{} = schemes) do
    if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
      {:ok, schemes}
    else
      {:error, "expected a map from binary scheme names to {module, keyword_options}"}
    end
  end

  def validate_source_schemes(_schemes),
    do: {:error, "expected a map from binary scheme names to {module, keyword_options}"}

  @impl ImagePipe.Parser
  def parse(%Plug.Conn{} = conn, opts) do
    with {:ok, parsed_request} <- parse_request(conn, opts) do
      PlanBuilder.to_plan(parsed_request, opts)
    end
  end

  defp parse_request(%Plug.Conn{} = conn, opts) do
    case Path.split_endpoint(conn) do
      {:info, info_conn} -> parse_info_request(info_conn, opts)
      :image -> parse_image_request(conn, opts)
    end
  end

  defp parse_image_request(%Plug.Conn{} = conn, opts) do
    imgproxy_opts = Keyword.get(opts, :imgproxy, [])

    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- verify_signature(signature, signed_path, opts),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <-
           Options.parse(
             option_segments,
             preset_config(imgproxy_opts),
             request_defaults(imgproxy_opts)
           ),
         {:ok, source_path, source_format} <-
           Path.parse_source(source_kind, raw_source_path, source_parsing_config(opts)) do
      parsed_request(
        signature,
        source_path,
        source_format,
        request_options
      )
    end
  end

  defp parse_info_request(%Plug.Conn{} = conn, opts) do
    imgproxy_opts = Keyword.get(opts, :imgproxy, [])

    with {:ok, signature, signed_path, path_info} <- Path.extract(conn),
         :ok <- verify_signature(signature, signed_path, opts),
         {:ok, option_segments, source_kind, raw_source_path} <- Path.split_source(path_info),
         {:ok, request_options} <-
           Options.parse(
             option_segments,
             preset_config(imgproxy_opts),
             request_defaults(imgproxy_opts)
           ),
         {:ok, source_path, _source_format} <-
           Path.parse_source_no_extension(
             source_kind,
             raw_source_path,
             source_parsing_config(opts)
           ) do
      {:ok,
       %ParsedRequest{
         signature: signature,
         source_kind: :plain,
         source_path: source_path,
         pipelines: request_options.pipelines,
         info?: true,
         auto_rotate: false,
         output: request_options.output,
         policy: request_options.policy,
         cache: request_options.cache,
         response: request_options.response
       }}
    end
  end

  @impl ImagePipe.Parser
  def handle_error(%Plug.Conn{} = conn, {:error, :invalid_signature}) do
    send_signature_error(conn, :invalid_signature)
  end

  def handle_error(
        %Plug.Conn{} = conn,
        {:error, {:invalid_signature_encoding, _signature}}
      ) do
    send_signature_error(conn, :invalid_signature_encoding)
  end

  def handle_error(%Plug.Conn{} = conn, {:error, {:unsupported_signature, _signature}}) do
    send_signature_error(conn, :unsupported_signature)
  end

  def handle_error(%Plug.Conn{} = conn, {:error, reason}) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(400, "invalid image request: #{inspect(reason)}")
  end

  defp send_signature_error(%Plug.Conn{} = conn, reason) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(403, "invalid image request: #{inspect(reason)}")
  end

  defp verify_signature(signature, signed_path, opts) do
    Signature.verify(signature, signed_path, signature_config(opts))
  end

  defp signature_config(opts) do
    opts
    |> Keyword.get(:imgproxy, [])
    |> Keyword.get(:signature, Signature.disabled())
  end

  defp preset_config(imgproxy_opts) do
    Keyword.get(imgproxy_opts, :presets, Presets.empty())
  end

  # Resolve the neutral plan/output defaults for the direct-parse path (opts that
  # were not run through `validate_options!`). Routing the neutral subset through
  # `Config.resolve!/2` keeps a single resolution path; it is idempotent with
  # `validate_options!`, so already-validated opts resolve to the same values.
  defp request_defaults(imgproxy_opts) do
    {neutral, _rest} = Keyword.split(imgproxy_opts, ImagePipe.Config.keys())
    ImagePipe.Config.resolve!(neutral, imgproxy_overlay())
  end

  defp source_parsing_config(opts) do
    imgproxy_opts = Keyword.get(opts, :imgproxy, [])

    [
      source_url_encryption: Keyword.get(imgproxy_opts, :source_url_encryption),
      base64_url_includes_filename:
        Keyword.get(imgproxy_opts, :base64_url_includes_filename, false)
    ]
  end

  defp normalize_source_encryption(validated) do
    {source_url_encryption, validated} = Keyword.pop(validated, :source_url_encryption_key)

    Keyword.put(validated, :source_url_encryption, source_url_encryption)
  end

  defp valid_source_scheme_entry?({scheme, {translator, translator_opts}}) do
    is_binary(scheme) and valid_source_scheme_translator?(translator) and
      Keyword.keyword?(translator_opts)
  end

  defp valid_source_scheme_entry?(_entry), do: false

  defp valid_source_scheme_translator?(translator) when is_atom(translator) do
    Code.ensure_loaded?(translator) and function_exported?(translator, :translate, 2)
  end

  defp valid_source_scheme_translator?(_translator), do: false

  defp parsed_request(
         signature,
         source_path,
         source_format,
         request_options
       ) do
    output_format = source_format || request_options.output.format

    {:ok,
     %ParsedRequest{
       signature: signature,
       source_kind: :plain,
       source_path: source_path,
       pipelines: request_options.pipelines,
       auto_rotate: request_options.auto_rotate,
       output: %{request_options.output | format: output_format},
       policy: request_options.policy,
       cache: request_options.cache,
       response: request_options.response
     }}
  end
end
