defmodule ImagePipe.Output.Encoder do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage, as: VixMutableImage
  alias Vix.Vips.Operation

  @doc """
  Returns libvips encoder limits for `ImagePipe.Output.Clamp`.

  `:max_dimension` limits each axis; `:max_pixels` limits total pixels.
  `:infinity` means no practical limit. The producer takes the minimum of
  these limits and the host's `max_result_*` caps before calling `Clamp.clamp/3`.
  """
  @spec encoder_limit(Format.output_format()) :: %{
          max_dimension: pos_integer() | :infinity,
          max_pixels: pos_integer() | :infinity
        }
  def encoder_limit(:jpeg_xl), do: %{max_dimension: :infinity, max_pixels: :infinity}
  def encoder_limit(:webp), do: %{max_dimension: 16_383, max_pixels: :infinity}
  def encoder_limit(:avif), do: %{max_dimension: 16_384, max_pixels: :infinity}
  def encoder_limit(:jpeg), do: %{max_dimension: 65_535, max_pixels: :infinity}
  def encoder_limit(:png), do: %{max_dimension: :infinity, max_pixels: :infinity}

  @doc "Encodes the image using the source ICC profile retained by input conditioning, or nil."
  @spec stream_output(VixImage.t(), Resolved.t(), binary() | nil, keyword()) ::
          {:ok, Enumerable.t(), String.t(), map() | nil}
          | {:error, {:encode, Exception.t(), list()}}
          | {:error, {:decode, term()}}
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, source_profile, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, finalized} <- finalize(image, resolved_output, source_profile) do
      deliver(finalized, resolved_output, mime_type, suffix, opts)
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # Pick the delivery path: a quality search (crop- or full-scored above/below the
  # internal crossover) when one is configured and supported and the host cap does
  # not skip it; otherwise stream the finalized image once.
  defp deliver(finalized, resolved_output, mime_type, suffix, opts) do
    if search?(resolved_output) and Format.supports_quality?(resolved_output.format) do
      case scorer_mode(finalized, resolved_output) do
        :skip -> lazy_output(finalized, resolved_output, mime_type, suffix, opts)
        scorer -> search_output(finalized, resolved_output, mime_type, scorer, opts)
      end
    else
      lazy_output(finalized, resolved_output, mime_type, suffix, opts)
    end
  end

  # JPEG XL cannot stream (see `encode_jxl_buffer/2`): encode to a buffer and
  # deliver it through the same one-element-list contract the search path uses.
  defp lazy_output(
         finalized,
         %Resolved{format: :jpeg_xl, quality: quality} = resolved,
         mime_type,
         _suffix,
         _opts
       ) do
    case encode_jxl_buffer(finalized, quality, Resolved.jxl_effort(resolved)) do
      {:ok, binary} -> {:ok, [binary], mime_type, nil}
      {:error, _reason} = err -> err
    end
  end

  defp lazy_output(finalized, resolved_output, mime_type, suffix, opts) do
    case encoder_tokens(resolved_output.encoder_options) do
      [] ->
        image_module = Keyword.get(opts, :image_module, Image)
        stream = image_module.stream!(finalized, output_options(suffix, resolved_output))
        {:ok, stream, mime_type, nil}

      tokens ->
        vsuffix = vix_suffix(suffix, resolved_output.quality, tokens)
        stream = VixImage.write_to_stream(finalized, vsuffix)
        {:ok, stream, mime_type, nil}
    end
  end

  # A quality search runs when a search objective or a hard byte budget is set.
  defp search?(%Resolved{
         format: :webp,
         encoder_options: %WebpOptions{lossless: true}
       }),
       do: false

  defp search?(%Resolved{quality_search: quality_search, max_bytes: max_bytes}),
    do: quality_search != :none or max_bytes != nil

  # The host max_resolution cap disables search first; otherwise the internal
  # crossover selects crop or full-frame scoring. max_bytes alone has no descriptor
  # and uses max_resolution=0, so it never skips.
  defp scorer_mode(finalized, %Resolved{quality_search: quality_search}) do
    megapixels = Image.width(finalized) * Image.height(finalized) / 1_000_000
    max_resolution = max_resolution_of(quality_search)

    cond do
      EncodeSearch.skip?(%{max_resolution: max_resolution}, megapixels) -> :skip
      crop?(quality_search, megapixels) -> :crop
      true -> :full
    end
  end

  defp max_resolution_of(%{max_resolution: mr}), do: mr
  defp max_resolution_of(:none), do: 0

  # Crop scoring only applies to the Ssimulacra2 strategy (it tiles the SSIMULACRA2
  # metric). A :size, butteraugli, or max_bytes-alone search above the crossover
  # does no crop scoring, so it stays :full and is not mislabeled :crop in telemetry.
  defp crop?(%RQS.Ssimulacra2{}, megapixels), do: megapixels > CropScore.crossover_megapixels()
  defp crop?(_quality_search, _megapixels), do: false

  # The search owns building the encode/score closures, the iteration cap, and
  # the objective/cap/confirm phases; we only hand it the finalized image and the
  # chosen scorer, wrapping the winning buffer as a one-element list so the
  # streaming contract is unchanged.
  defp search_output(finalized, resolved_output, mime_type, scorer, opts) do
    search_opts = [scorer: scorer, telemetry_opts: ImagePipe.Telemetry.telemetry_opts(opts)]

    case EncodeSearch.run(finalized, resolved_output, search_opts) do
      {:ok, binary, meta} -> {:ok, [binary], mime_type, meta}
      {:error, _reason} = err -> err
    end
  end

  @doc """
  Encode `image` to an in-memory binary at a specific `quality`, returning
  `{:ok, binary}`. Used by the quality-search loop, which probes candidate
  qualities against an already-finalized image; the caller owns finalization
  and reuses the resolved suffix. Errors are tagged `{:encode, exception, stack}`
  to match the module's existing encode-error shape.
  """
  @spec encode_to_buffer(VixImage.t(), Resolved.t(), 1..100) ::
          {:ok, binary()} | {:error, {:encode, Exception.t(), list()}}
  def encode_to_buffer(%VixImage{} = image, %Resolved{format: :jpeg_xl} = resolved, quality),
    do: encode_jxl_buffer(image, quality, Resolved.jxl_effort(resolved))

  def encode_to_buffer(%VixImage{} = image, %Resolved{} = resolved_output, quality) do
    with {:ok, _mime_type, suffix} <- output_format(resolved_output) do
      buffer_for(image, suffix, quality, encoder_tokens(resolved_output.encoder_options))
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # Use the Image wrapper when there are no encoder options.
  defp buffer_for(image, suffix, quality, []) do
    case Image.write(image, :memory, suffix: suffix, quality: quality) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  end

  # Encoder options present: encode via Vix with a bracketed libvips suffix.
  defp buffer_for(image, suffix, quality, tokens) do
    case VixImage.write_to_buffer(image, vix_suffix(suffix, {:quality, quality}, tokens)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  end

  # JPEG XL is written through Vix directly to a seekable memory buffer: the
  # `image` package rejects the `.jxl` suffix, and `jxlsave` cannot write a
  # non-seekable delivery pipe (`Image.stream!`). Quality drives libjxl's `Q`
  # knob; `:default` leaves libjxl's own default butteraugli distance. `effort`
  # (1..9 or `nil`) sets the encode effort.
  defp encode_jxl_buffer(%VixImage{} = image, quality, effort) do
    case VixImage.write_to_buffer(image, jxl_vix_suffix(quality, effort)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  @doc """
  Encode `image` to a JPEG XL buffer at a target butteraugli `distance`
  (0.0–25.0) and encode `effort` (1..9 or `nil`). Used by the native-JXL
  autoquality strategy. Failures surface as `{:error, {:encode, _, _}}`,
  consistent with `encode_jxl_buffer/3`.
  """
  @spec encode_jxl_distance(VixImage.t(), number(), nil | 1..9) ::
          {:ok, binary()} | {:error, term()}
  def encode_jxl_distance(%VixImage{} = image, distance, effort) do
    case VixImage.write_to_buffer(image, jxl_vix_suffix({:distance, distance}, effort)) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # `effort` (1..9) is the JPEG XL encode effort; `nil` omits the token, leaving
  # libvips `jxlsave`'s own default (7) — so a `nil` effort is byte-identical to an
  # explicit `effort=7`.
  defp jxl_vix_suffix(quality, effort) do
    case Enum.reject([quality_token(quality), effort_token(effort)], &is_nil/1) do
      [] -> ".jxl"
      tokens -> ".jxl[" <> Enum.join(tokens, ",") <> "]"
    end
  end

  defp quality_token(:default), do: nil
  defp quality_token({:quality, value}), do: "Q=#{value}"
  defp quality_token({:distance, value}), do: "distance=#{value}"
  defp quality_token(value) when is_integer(value), do: "Q=#{value}"

  defp effort_token(nil), do: nil
  defp effort_token(effort) when is_integer(effort), do: "effort=#{effort}"

  # ".jpg" + Q + option tokens -> ".jpg[Q=75,interlace=true,...]". Q omitted for :default.
  defp vix_suffix(suffix, quality, tokens) do
    case Enum.reject([quality_token(quality) | tokens], &is_nil/1) do
      [] -> suffix
      parts -> "#{suffix}[#{Enum.join(parts, ",")}]"
    end
  end

  # libvips suffix tokens (k=v, dash-named) from the negotiated encoder-option struct.
  defp encoder_tokens(nil), do: []

  defp encoder_tokens(%JpegOptions{} = o) do
    option_tokens(
      interlace: o.interlace,
      "subsample-mode": o.subsample_mode,
      "trellis-quant": o.trellis_quant,
      "overshoot-deringing": o.overshoot_deringing,
      "optimize-scans": o.optimize_scans,
      "quant-table": o.quant_table
    )
  end

  defp encoder_tokens(%PngOptions{} = o) do
    option_tokens(
      interlace: o.interlace,
      palette: o.palette,
      bitdepth: o.bitdepth,
      filter: o.filter
    )
  end

  defp encoder_tokens(%WebpOptions{} = o) do
    option_tokens(
      lossless: o.lossless,
      "near-lossless": o.near_lossless,
      "smart-subsample": o.smart_subsample,
      preset: o.preset,
      effort: o.effort
    )
  end

  defp encoder_tokens(%AvifOptions{} = o) do
    option_tokens("subsample-mode": o.subsample_mode, effort: o.effort)
  end

  defp encoder_tokens(%JxlOptions{}), do: []

  defp option_tokens(pairs) do
    for {k, v} <- pairs, not is_nil(v), do: "#{k}=#{token_value(v)}"
  end

  defp token_value(true), do: "true"
  defp token_value(false), do: "false"
  defp token_value(v) when is_atom(v), do: Atom.to_string(v)
  defp token_value(v), do: to_string(v)

  defp encode_error(reason),
    do: ArgumentError.exception("failed to encode to buffer: #{inspect(reason)}")

  # Materialize on the producer's stack so corrupt-source failures return decode
  # errors (415). Doing this inside mutate would crash the linked MutableImage
  # GenServer. Color finalization and metadata stripping then use the in-memory image.
  defp finalize(image, %Resolved{} = resolved, source_profile) do
    case VixImage.copy_memory(image) do
      {:ok, mem} ->
        with {:ok, flattened} <- flatten_for_format(mem, resolved) do
          color_result(flattened, resolved, source_profile)
        end

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  # Non-alpha formats need opaque pixels. Flatten onto the resolved background
  # (default white), ignoring its alpha. Already-opaque images pass through,
  # including those flattened by a request's background transform.
  defp flatten_for_format(image, %Resolved{format: format, flatten_background: background}) do
    if Format.supports_alpha?(format) or not Image.has_alpha?(image) do
      {:ok, image}
    else
      case Image.flatten(image, background: Color.to_rgb_list(background)) do
        {:ok, flattened} -> {:ok, flattened}
        {:error, reason} -> {:error, {:encode, flatten_error(reason), []}}
      end
    end
  end

  defp flatten_error(reason),
    do:
      ArgumentError.exception("failed to flatten alpha for non-alpha output: #{inspect(reason)}")

  # Explicit conversion embeds the chosen target profile. Keep it out of
  # maybe_drop_profile/2, which would strip that profile. strip_metadata preserves
  # the ICC for this policy while removing EXIF/XMP/IPTC.
  defp color_result(
         image,
         %Resolved{color_profile: {:convert, target}} = resolved,
         _source_profile
       ) do
    with {:ok, image} <- convert_to_target(image, target, resolved.format) do
      {:ok, strip_metadata(image, resolved)}
    end
  end

  defp color_result(image, %Resolved{} = resolved, source_profile) do
    keep? =
      resolved.color_profile == :preserve_source and
        Format.supports_color_profile?(resolved.format)

    with {:ok, image} <- restore_backup(image, source_profile),
         {:ok, image} <- apply_color_result(image, keep?, source_profile != nil),
         {:ok, image} <- maybe_drop_profile(image, keep?) do
      {:ok, strip_metadata(image, resolved)}
    end
  end

  # Export to the restored source profile, using its PCS and the image's bit depth.
  defp apply_color_result(image, true, true) do
    case Operation.icc_export(image,
           pcs: pcs(header_value(image, "icc-profile-data")),
           depth: icc_depth(image)
         ) do
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # Without a retained/imported profile, convert tagged images to the standard space.
  defp apply_color_result(image, false, false), do: to_standard(image)

  # keep && !imported (already in the source space) and !keep && imported (already
  # standard): nothing to do.
  defp apply_color_result(image, _keep?, _imported), do: {:ok, image}

  # Convert tagged images to sRGB or sGrey. Untagged images keep their pixels.
  defp to_standard(image) do
    case header_value(image, "icc-profile-data") do
      nil ->
        {:ok, image}

      _profile ->
        profile = standard_profile(VixImage.interpretation(image))

        case Operation.icc_transform(image, profile,
               embedded: true,
               pcs: pcs(header_value(image, "icc-profile-data")),
               depth: icc_depth(image)
             ) do
          {:ok, image} -> {:ok, image}
          {:error, reason} -> {:error, {:decode, reason}}
        end
    end
  end

  # Promote greyscale to three-band sRGB before target conversion. Declare sRGB
  # explicitly because untagged sources have no embedded input profile.
  # colourspace produces 8-bit UCHAR, matching libvips' default output depth.
  # Output-policy validation rejects named profile conversion with HDR preservation.
  # Dialyzer can't see through Vix's generated Operation typings, so it reports
  # the icc_transform call as failing; it succeeds at runtime.
  @dialyzer {:no_fail_call, convert_to_target: 3}
  defp convert_to_target(image, target, format) do
    if Format.supports_color_profile?(format) do
      with {:ok, srgb} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
           {:ok, converted} <-
             Operation.icc_transform(srgb, ColorProfile.path!(target), input_profile: "sRGB") do
        {:ok, converted}
      else
        {:error, reason} -> {:error, {:decode, reason}}
      end
    else
      {:ok, image}
    end
  end

  defp standard_profile(interpretation)
       when interpretation in [:VIPS_INTERPRETATION_B_W, :VIPS_INTERPRETATION_GREY16],
       do: "sGrey"

  defp standard_profile(_interpretation), do: "sRGB"

  # imgproxy `image_depth`: 16 for the 16-bit/scRGB interpretations, else 8.
  defp icc_depth(image) do
    case VixImage.interpretation(image) do
      :VIPS_INTERPRETATION_GREY16 -> 16
      :VIPS_INTERPRETATION_RGB16 -> 16
      :VIPS_INTERPRETATION_scRGB -> 16
      _ -> 8
    end
  end

  # Read PCS from ICC bytes 20–23. Match Transform.InputColorManagement so import
  # and export agree, without introducing an Output → Transform dependency.
  defp pcs(p) when is_binary(p) and byte_size(p) >= 128,
    do: if(binary_part(p, 20, 4) == "XYZ ", do: :VIPS_PCS_XYZ, else: :VIPS_PCS_LAB)

  defp pcs(_), do: :VIPS_PCS_LAB

  # icc_export targets the embedded profile, so restore the backed-up source blob
  # onto icc-profile-data first (no-op when absent), mirroring `RestoreColourProfile`.
  defp restore_backup(image, nil), do: {:ok, image}
  defp restore_backup(image, backup), do: {:ok, set_icc(image, backup)}

  # Removing a profile also removes its EXIF color-characterization tags,
  # even when general metadata stripping is disabled.
  @icc_remove_fields [
    "icc-profile-data",
    "exif-ifd0-WhitePoint",
    "exif-ifd0-PrimaryChromaticities",
    "exif-ifd2-ColorSpace"
  ]

  defp maybe_drop_profile(image, true), do: {:ok, image}
  defp maybe_drop_profile(image, false), do: {:ok, remove_fields(image, @icc_remove_fields)}

  # Strip EXIF/XMP/IPTC (keeping copyright/artist iff kcr).
  # `minimize_metadata` enumerates and removes all metadata
  # header fields — crucially the individual `exif-ifd0-*`/`exif-gps-*` entries,
  # which survive removing just the serialized "exif-data" blob and would otherwise
  # be re-serialized into EXIF on encode (leaking GPS/copyright). It also removes
  # the ICC profile, so the color switch above must
  # already have run. If minimize_metadata fails (malformed/absent EXIF), fall back
  # to blob removal.
  defp strip_metadata(image, %Resolved{strip_metadata: false}), do: image

  defp strip_metadata(image, %Resolved{} = resolved) do
    keep = if resolved.keep_copyright, do: [:copyright, :artist], else: []

    icc =
      if resolved.color_profile == :strip, do: nil, else: header_value(image, "icc-profile-data")

    minimized =
      case Image.minimize_metadata(image, keep: keep) do
        {:ok, stripped} ->
          stripped

        {:error, _} ->
          remove_fields(
            image,
            ["exif-data", "xmp-data", "iptc-data"] ++
              icc_fields(resolved)
          )
      end

    restore_icc(minimized, icc)
  end

  defp icc_fields(%Resolved{color_profile: :strip}), do: ["icc-profile-data"]
  defp icc_fields(%Resolved{}), do: []

  # Explicit string field names via Vix mutate. We deliberately avoid:
  #   * the libvips `strip` write flag (it also removes the ICC profile);
  #   * `Image.remove_metadata(_, :xmp)` — `image` v0.67 maps :xmp -> "xmp-dataa"
  #     (a typo), silently retaining XMP;
  #   * default `remove_metadata`/`minimize_metadata` field-enumeration on the
  #     non-kcr paths — they over-strip the ICC profile.
  defp remove_fields(image, fields) do
    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        Enum.each(fields, &VixMutableImage.remove(mut, &1))
        :ok
      end)

    image
  end

  defp header_value(image, field) do
    case VixImage.header_value(image, field) do
      {:ok, value} -> value
      _ -> nil
    end
  end

  defp restore_icc(image, nil), do: image
  defp restore_icc(image, icc), do: set_icc(image, icc)

  defp set_icc(image, icc) do
    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        VixMutableImage.set(mut, "icc-profile-data", :VipsBlob, icc)
        :ok
      end)

    image
  end

  defp output_format(%Resolved{format: format}) when is_atom(format) do
    case Format.mime_type(format) do
      {:ok, mime_type} -> {:ok, mime_type, Format.suffix!(mime_type)}
      :error -> {:error, {:encode, unsupported_output_format_error(format), []}}
    end
  end

  defp unsupported_output_format_error(format) do
    ArgumentError.exception("unsupported output format: #{inspect(format)}")
  end

  defp output_options(suffix, %Resolved{quality: {:quality, value}}),
    do: [suffix: suffix, quality: value]

  defp output_options(suffix, %Resolved{quality: :default}), do: [suffix: suffix]
end
