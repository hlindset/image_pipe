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

  # imgproxy's per-format default quality (`IMGPROXY_FORMAT_QUALITY`). A host
  # override **merges** onto these (imgproxy `maps.Copy(c.FormatQuality, fq)`),
  # so configuring one format leaves the others at their defaults rather than
  # dropping them to the global `quality`.
  @default_format_quality %{webp: 79, avif: 63, jpeg_xl: 77}

  @imgproxy_schema NimbleOptions.new!(
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
                     ],
                     auto_rotate: [
                       type: :boolean,
                       default: true
                     ],
                     strip_metadata: [type: :boolean, default: true],
                     keep_copyright: [type: :boolean, default: true],
                     quality: [type: :pos_integer, default: 80],
                     format_quality: [
                       type: {:map, :atom, :pos_integer},
                       default: @default_format_quality
                     ],
                     strip_color_profile: [type: :boolean, default: true],
                     preserve_hdr: [type: :boolean, default: false],
                     smart_crop_face_detection: [type: :boolean, default: false],
                     autoquality_method: [
                       type: {:in, [:none, :size, :ssimulacra2, :butteraugli]},
                       default: :none
                     ],
                     # Per-metric search target on each metric's own scale (SSIMULACRA2
                     # score 0–100, butteraugli distance 0–25, size byte count). A
                     # single cross-metric scalar is incoherent, so this is keyed by
                     # metric; built-in per-metric defaults apply where absent (`:size`
                     # has no default — it stays required). Range-checked per metric in
                     # `validate_quality_config!`.
                     autoquality_target: [
                       type: {:map, :atom, {:or, [:integer, :float]}},
                       default: %{}
                     ],
                     autoquality_min_quality: [type: :pos_integer, default: 70],
                     autoquality_max_quality: [type: :pos_integer, default: 80],
                     # Per-metric symmetric tolerance band on the metric's own scale
                     # (SSIMULACRA2 points on 0–100, butteraugli distance), NOT imgproxy's
                     # DSSIM `allowed_error`. Per-metric for the same scale reason as
                     # target; built-in defaults apply where absent (ssimulacra2 1.0,
                     # butteraugli 0.1). `:size` has no band. Non-negative is enforced in
                     # `validate_quality_config!`; the URL form is guarded by the grammar.
                     autoquality_allowed_error: [
                       type: {:map, :atom, {:or, [:integer, :float]}},
                       default: %{}
                     ],
                     # Per-format quality brackets the autoquality search operates
                     # within. AVIF uses a tight 60–65 band; JPEG XL gets a wide
                     # 45–80 band so the search can actually reach the ssim2 target
                     # per image (JXL needs ~Q70 on photos but only ~Q55 on screen
                     # content, and the base 70 floor would otherwise pin it high and
                     # overshoot). A format absent here falls back to the base
                     # autoquality_min_quality/max_quality.
                     autoquality_format_min_quality: [
                       type: {:map, :atom, :pos_integer},
                       default: %{avif: 60, jpeg_xl: 45}
                     ],
                     autoquality_format_max_quality: [
                       type: {:map, :atom, :pos_integer},
                       default: %{avif: 65, jpeg_xl: 80}
                     ],
                     autoquality_max_resolution: [type: :non_neg_integer, default: 0],
                     autoquality_max_iterations: [type: :pos_integer, default: 6]
                   )

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
    case NimbleOptions.validate(imgproxy_opts, @imgproxy_schema) do
      {:ok, validated} ->
        validate_quality_config!(validated)
        validate_autoquality_brackets!(validated)

        validated
        |> Keyword.update(:signature, Signature.disabled(), &Signature.normalize_config!/1)
        |> normalize_source_encryption()

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid imgproxy config: #{Exception.message(error)}"
    end
  end

  defp validate_imgproxy_options!(_imgproxy_opts),
    do: raise(ArgumentError, "invalid imgproxy options: expected a keyword list")

  # Range-check the host-config default quality knobs. NimbleOptions enforces
  # pos_integer / map shape but not the 1..100 ceiling, so assert it here at the
  # config boundary before the value can reach the encoder.
  defp validate_quality_config!(validated) do
    quality = Keyword.fetch!(validated, :quality)

    unless quality in 1..100 do
      raise ArgumentError,
            "invalid imgproxy config: quality (#{quality}) must be between 1 and 100"
    end

    Enum.each(Keyword.fetch!(validated, :format_quality), fn {format, q} ->
      unless q in 1..100 do
        raise ArgumentError,
              "invalid imgproxy config: format_quality #{inspect(format)} (#{q}) " <>
                "must be between 1 and 100"
      end
    end)

    validate_autoquality_target_config!(Keyword.fetch!(validated, :autoquality_target))

    validate_autoquality_allowed_error_config!(
      Keyword.fetch!(validated, :autoquality_allowed_error)
    )

    :ok
  end

  @autoquality_metrics [:size, :ssimulacra2, :butteraugli]

  defp validate_autoquality_target_config!(target_map) do
    Enum.each(target_map, fn {metric, value} ->
      unless metric in @autoquality_metrics do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_target has unknown metric #{inspect(metric)}"
      end

      unless valid_target_value?(metric, value) do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_target #{inspect(metric)} (#{inspect(value)}) " <>
                "is out of range for that metric"
      end
    end)
  end

  defp valid_target_value?(:size, value), do: is_integer(value) and value > 0

  defp valid_target_value?(:ssimulacra2, value),
    do: is_number(value) and value >= 0 and value <= 100

  defp valid_target_value?(:butteraugli, value),
    do: is_number(value) and value >= 0 and value <= 25

  defp validate_autoquality_allowed_error_config!(error_map) do
    Enum.each(error_map, fn {metric, value} ->
      unless metric in [:ssimulacra2, :butteraugli] do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_allowed_error has unsupported metric " <>
                "#{inspect(metric)} (only :ssimulacra2/:butteraugli)"
      end

      unless is_number(value) and value >= 0 do
        raise ArgumentError,
              "invalid imgproxy config: autoquality_allowed_error #{inspect(metric)} " <>
                "(#{inspect(value)}) must be a non-negative number"
      end
    end)
  end

  # NimbleOptions validates each autoquality quality is 1..100 but cannot express
  # the cross-field constraint that the effective per-format bracket is ordered.
  # `Output.Policy.resolve_search/2` falls back per side independently
  # (`format_min[fmt]` else base min; `format_max[fmt]` else base max), so a
  # config like `format_min: %{jpeg: 88}` with base `max: 72` resolves jpeg to an
  # inverted 88..72 bracket. Reject it here, at the config boundary, before it can
  # reach the search.
  defp validate_autoquality_brackets!(validated) do
    base_min = Keyword.fetch!(validated, :autoquality_min_quality)
    base_max = Keyword.fetch!(validated, :autoquality_max_quality)
    format_min = Keyword.fetch!(validated, :autoquality_format_min_quality)
    format_max = Keyword.fetch!(validated, :autoquality_format_max_quality)

    if base_min > base_max do
      raise ArgumentError,
            "invalid imgproxy config: autoquality_min_quality (#{base_min}) exceeds " <>
              "autoquality_max_quality (#{base_max})"
    end

    format_min
    |> Map.keys()
    |> Enum.concat(Map.keys(format_max))
    |> Enum.uniq()
    |> Enum.each(fn format ->
      effective_min = Map.get(format_min, format, base_min)
      effective_max = Map.get(format_max, format, base_max)

      if effective_min > effective_max do
        raise ArgumentError,
              "invalid imgproxy config: effective autoquality bracket for #{inspect(format)} " <>
                "is inverted (min #{effective_min} > max #{effective_max}); reconcile " <>
                "autoquality_format_min_quality/autoquality_format_max_quality with the base " <>
                "autoquality_min_quality/autoquality_max_quality"
      end
    end)

    :ok
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

  defp request_defaults(imgproxy_opts) do
    [
      auto_rotate: Keyword.get(imgproxy_opts, :auto_rotate, true),
      strip_metadata: Keyword.get(imgproxy_opts, :strip_metadata, true),
      keep_copyright: Keyword.get(imgproxy_opts, :keep_copyright, true),
      strip_color_profile: Keyword.get(imgproxy_opts, :strip_color_profile, true),
      preserve_hdr: Keyword.get(imgproxy_opts, :preserve_hdr, false),
      quality: Keyword.get(imgproxy_opts, :quality, 80),
      format_quality:
        Map.merge(@default_format_quality, Keyword.get(imgproxy_opts, :format_quality, %{})),
      autoquality_method: Keyword.get(imgproxy_opts, :autoquality_method, :none),
      autoquality_target: Keyword.get(imgproxy_opts, :autoquality_target, %{}),
      autoquality_min_quality: Keyword.get(imgproxy_opts, :autoquality_min_quality, 70),
      autoquality_max_quality: Keyword.get(imgproxy_opts, :autoquality_max_quality, 80),
      autoquality_allowed_error: Keyword.get(imgproxy_opts, :autoquality_allowed_error, %{}),
      autoquality_format_min_quality:
        Keyword.get(imgproxy_opts, :autoquality_format_min_quality, %{avif: 60, jpeg_xl: 45}),
      autoquality_format_max_quality:
        Keyword.get(imgproxy_opts, :autoquality_format_max_quality, %{avif: 65, jpeg_xl: 80}),
      autoquality_max_resolution: Keyword.get(imgproxy_opts, :autoquality_max_resolution, 0),
      autoquality_max_iterations: Keyword.get(imgproxy_opts, :autoquality_max_iterations, 6)
    ]
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
