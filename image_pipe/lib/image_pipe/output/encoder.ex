defmodule ImagePipe.Output.Encoder do
  @moduledoc false

  alias ImagePipe.BitDepth
  alias ImagePipe.Format
  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.Output.EncodeSearch
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS
  alias ImagePipe.Output.Ssim2Metric.CropScore
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.SrgbProfile
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage, as: VixMutableImage
  alias Vix.Vips.Operation

  @doc """
  Returns libvips encoder limits for `ImagePipe.Transform.Clamp`.

  `:max_dimension` limits each axis; `:max_pixels` limits total pixels.
  `:infinity` means no practical limit. The producer takes the minimum of
  these limits and the host's `max_result_*` caps before calling `Clamp.clamp/3`.
  """
  @spec encoder_limit(Format.output_format()) :: %{
          max_dimension: pos_integer() | :infinity,
          max_pixels: pos_integer() | :infinity
        }
  def encoder_limit(:webp), do: %{max_dimension: 16_383, max_pixels: :infinity}
  def encoder_limit(:avif), do: %{max_dimension: 16_384, max_pixels: :infinity}
  def encoder_limit(:jpeg), do: %{max_dimension: 65_500, max_pixels: :infinity}
  def encoder_limit(:png), do: %{max_dimension: :infinity, max_pixels: :infinity}

  @typedoc """
  The source ICC profile input conditioning backed up (or `nil`), and whether it
  was imported into the working space.
  """
  @type source_color :: {binary() | nil, boolean()}

  @doc "Encodes the image using the source color state from input conditioning."
  @spec stream_output(VixImage.t(), Resolved.t(), source_color(), keyword()) ::
          {:ok, Enumerable.t(), String.t(), map() | nil}
          | {:error, {:encode, Exception.t(), list()}}
          | {:error, {:decode, term()}}
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, source_color, opts) do
    {mime_type, suffix} = output_format(resolved_output)

    with {:ok, finalized} <- finalize(image, resolved_output, source_color),
         {:ok, finalized, resolved_output} <- fit_png_depth(finalized, resolved_output) do
      deliver(finalized, resolved_output, mime_type, suffix, opts)
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  # Pick the delivery path: a quality search (crop- or full-scored above/below the
  # internal crossover) when one is configured and supported; otherwise stream the
  # finalized image once.
  defp deliver(finalized, resolved_output, mime_type, suffix, opts) do
    if search?(resolved_output) and Format.supports_quality?(resolved_output.format) do
      search_output(
        finalized,
        resolved_output,
        mime_type,
        scorer_mode(finalized, resolved_output),
        opts
      )
    else
      lazy_output(finalized, resolved_output, mime_type, suffix, opts)
    end
  end

  defp lazy_output(finalized, resolved_output, mime_type, suffix, opts) do
    image_module = Keyword.get(opts, :image_module, VixImage)
    vsuffix = vix_suffix(suffix, resolved_output.quality, save_tokens(resolved_output))
    {:ok, image_module.write_to_stream(finalized, vsuffix), mime_type, nil}
  end

  # A quality search runs when a search objective or a hard byte budget is set.
  defp search?(%Resolved{quality_search: quality_search, max_bytes: max_bytes}),
    do: quality_search != :none or max_bytes != nil

  # The internal crossover selects crop or full-frame scoring.
  defp scorer_mode(finalized, %Resolved{quality_search: quality_search}) do
    megapixels = Image.width(finalized) * Image.height(finalized) / 1_000_000
    if crop?(quality_search, megapixels), do: :crop, else: :full
  end

  # Crop scoring only applies to the Ssimulacra2 strategy (it tiles the SSIMULACRA2
  # metric). A max_bytes-alone search above the crossover
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
  def encode_to_buffer(%VixImage{} = image, %Resolved{} = resolved_output, quality) do
    {_mime_type, suffix} = output_format(resolved_output)
    vsuffix = vix_suffix(suffix, {:quality, quality}, save_tokens(resolved_output))

    case VixImage.write_to_buffer(image, vsuffix) do
      {:ok, binary} -> {:ok, binary}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp quality_token(:default), do: nil
  defp quality_token({:quality, value}), do: "Q=#{value}"
  defp quality_token(value) when is_integer(value), do: "Q=#{value}"

  # ".jpg" + Q + option tokens -> ".jpg[Q=75,interlace=true,...]". Q omitted for :default.
  defp vix_suffix(suffix, quality, tokens) do
    case Enum.reject([quality_token(quality) | tokens], &is_nil/1) do
      [] -> suffix
      parts -> "#{suffix}[#{Enum.join(parts, ",")}]"
    end
  end

  defp save_tokens(%Resolved{} = resolved) do
    options = resolved.encoder_options || default_encoder_options(resolved.format)
    Enum.reject([keep_token(resolved) | encoder_tokens(options)], &is_nil/1)
  end

  # Without settings from the host or the request, JPEG and PNG still get the
  # defaults `encoder_tokens/1` adds.
  defp default_encoder_options(:jpeg), do: %JpegOptions{}
  defp default_encoder_options(:png), do: %PngOptions{}
  defp default_encoder_options(_format), do: nil

  # Stripping happens when libvips saves: its `keep` option leaves out EXIF,
  # XMP, IPTC, and other metadata, so nothing is parsed or removed first. The
  # ICC profile left by color finalization stays. EXIF stays for kept
  # copyright and artist, and for a density other than 72 dpi: libvips writes
  # density into EXIF for every format but PNG, which has pHYs. Viewers
  # assume 72 dpi without it.
  defp keep_token(%Resolved{strip_metadata: false}), do: nil

  defp keep_token(%Resolved{} = resolved),
    do: if(exif_kept?(resolved), do: "keep=icc:exif", else: "keep=icc")

  defp exif_kept?(%Resolved{keep_copyright: true}), do: true

  defp exif_kept?(%Resolved{format: format, dpi: dpi}),
    do: format != :png and dpi not in [nil, 72]

  # libvips suffix tokens (k=v, dash-named) from the negotiated encoder-option struct.
  defp encoder_tokens(nil), do: []

  # Huffman tables computed for the image make files up to 18% smaller (2-4%
  # for photos) for 1-4 ms of encode time, paid once per cached response.
  defp encoder_tokens(%JpegOptions{} = o) do
    option_tokens(
      "optimize-coding": true,
      interlace: o.interlace,
      "subsample-mode": o.subsample_mode,
      "trellis-quant": o.trellis_quant,
      "overshoot-deringing": o.overshoot_deringing,
      "optimize-scans": o.optimize_scans,
      "quant-table": o.quant_table
    )
  end

  # libvips defaults to compression 6 with no row filter. Compression 3 with
  # the Paeth filter makes truecolor files 15-35% smaller and encodes faster.
  # Adaptive filtering (`all`) is barely smaller but up to 2.5x slower. A
  # palette or a gray image below 8 bits compresses best unfiltered, and a
  # palette keeps compression 6: quantizing dominates its encode time, and
  # compression 3 makes it 2-4% larger.
  defp encoder_tokens(%PngOptions{} = o) do
    option_tokens(
      compression: if(png_palette?(o), do: nil, else: 3),
      interlace: o.interlace,
      palette: o.palette,
      bitdepth: o.bitdepth,
      filter: o.filter || png_filter(o)
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

  defp png_filter(%PngOptions{bitdepth: depth} = o) do
    if png_palette?(o) or depth in [1, 2, 4], do: nil, else: :paeth
  end

  # A PNG at 16 bits has no palette.
  defp png_palette?(%PngOptions{palette: palette, bitdepth: depth}),
    do: palette == true and depth != 16

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
  defp finalize(image, %Resolved{} = resolved, source_color) do
    case VixImage.copy_memory(image) do
      {:ok, mem} ->
        with {:ok, flattened} <- flatten_for_format(mem, resolved),
             {:ok, image} <- color_result(flattened, resolved, source_color) do
          {:ok, set_density(image, resolved)}
        end

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  # A palette holds 8-bit colors. Without a bit depth, libvips saves a 16-bit
  # image as 16-bit color and drops the palette, so it's narrowed first.
  defp fit_png_depth(
         image,
         %Resolved{format: :png, encoder_options: %PngOptions{bitdepth: depth, palette: true}} =
           resolved
       )
       when depth != 16 do
    with {:ok, image} <- narrow_to_8_bits(image), do: {:ok, image, resolved}
  end

  # PNG stores gray+alpha and color at 8 or 16 bits only, so a bit depth below
  # 8 applies to a one-band result and the rest encode at 8 bits, even from a
  # 16-bit image.
  defp fit_png_depth(
         image,
         %Resolved{format: :png, encoder_options: %PngOptions{bitdepth: depth}} = resolved
       )
       when depth in [1, 2, 4] do
    if Image.bands(image) == 1 do
      with {:ok, image} <- keep_gray_levels(image, depth), do: {:ok, image, resolved}
    else
      with {:ok, image} <- narrow_to_8_bits(image),
           do: {:ok, image, put_in(resolved.encoder_options.bitdepth, 8)}
    end
  end

  # Workaround for libvips 8.18: its saver widens 8-bit color to 16 bits by
  # 256 (with 255 special-cased), so 128 becomes 32768 instead of 32896. Gray
  # widens by 257. Widening here first scales every band by 257. Tracked in
  # image_plug-y7mu. A palette holds 8-bit colors, so the saver writes no
  # palette at 16 bits and widens the same way.
  defp fit_png_depth(
         image,
         %Resolved{format: :png, encoder_options: %PngOptions{bitdepth: 16}} = resolved
       ) do
    if VixImage.format(image) == :VIPS_FORMAT_UCHAR do
      with {:ok, image} <- widen_to_16_bits(image), do: {:ok, image, resolved}
    else
      {:ok, image, resolved}
    end
  end

  defp fit_png_depth(
         image,
         %Resolved{format: :png, encoder_options: %PngOptions{bitdepth: 8}} = resolved
       ) do
    with {:ok, image} <- narrow_to_8_bits(image), do: {:ok, image, resolved}
  end

  defp fit_png_depth(image, resolved), do: {:ok, image, resolved}

  defp narrow_to_8_bits(image) do
    case BitDepth.narrow_to_8_bits(image) do
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  end

  defp widen_to_16_bits(image) do
    interpretation =
      if Image.bands(image) < 3,
        do: :VIPS_INTERPRETATION_GREY16,
        else: :VIPS_INTERPRETATION_RGB16

    with {:ok, scaled} <- Operation.linear(image, [257.0], [0.0]),
         {:ok, wide} <- Operation.cast(scaled, :VIPS_FORMAT_USHORT),
         {:ok, wide} <- Operation.copy(wide, interpretation: interpretation) do
      {:ok, wide}
    else
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  end

  # Workaround for libvips 8.18: its libpng saver packs the low bits of each
  # gray value at 2 and 4 bits, so 150 at 4 bits reads back as 102, and at 1
  # bit writes every value but 0 as white. Its spng saver shifts by
  # 8 - bitdepth first, which this does. Tracked in image_plug-i14h.
  defp keep_gray_levels(image, depth) do
    shift = if VixImage.format(image) == :VIPS_FORMAT_USHORT, do: 16 - depth, else: 8 - depth

    with {:ok, shifted} <-
           Operation.boolean_const(image, :VIPS_OPERATION_BOOLEAN_RSHIFT, [shift * 1.0]),
         {:ok, shifted} <- Operation.cast(shifted, :VIPS_FORMAT_UCHAR) do
      {:ok, shifted}
    else
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  end

  # Non-alpha formats need opaque pixels, so transparency flattens onto white.
  # Already-opaque images pass through, including those flattened by a
  # request's background transform.
  defp flatten_for_format(image, %Resolved{format: format}) do
    if Format.supports_alpha?(format) or not Image.has_alpha?(image) do
      {:ok, image}
    else
      case flatten_onto_white(image) do
        {:ok, flattened} -> {:ok, flattened}
        {:error, reason} -> {:error, {:encode, flatten_error(reason), []}}
      end
    end
  end

  # libvips' flatten keeps its input's format and truncates, so it runs on
  # float and rounds back.
  defp flatten_onto_white(image) do
    color_bands = VixImage.bands(image) - 1

    with {:ok, white} <- Image.Pixel.to_pixel(image, [255, 255, 255]),
         {:ok, float} <- Operation.cast(image, :VIPS_FORMAT_FLOAT),
         {:ok, flattened} <- Operation.flatten(float, background: Enum.take(white, color_bands)),
         {:ok, rounded} <- Operation.round(flattened, :VIPS_OPERATION_ROUND_RINT) do
      Operation.cast(rounded, VixImage.format(image))
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
         source_color
       ) do
    with {:ok, image} <- convert_to_target(image, target, source_color) do
      {:ok, image |> tag_exif_color(target) |> strip_metadata(resolved)}
    end
  end

  # A tagged frame without a source-profile backup has nothing to keep: a step
  # that converted it to sRGB cleared the backup and left an sRGB-equivalent
  # profile in the header.
  defp color_result(image, %Resolved{} = resolved, {profile, imported?}) do
    keep? =
      resolved.color_profile == :preserve_source and
        (is_binary(profile) or is_nil(header_value(image, "icc-profile-data"))) and
        holds_profile_space?(resolved.format, profile)

    with {:ok, image} <- restore_backup(image, profile),
         {:ok, image} <- apply_color_result(image, keep?, imported?),
         {:ok, image} <- maybe_drop_profile(image, keep?) do
      {:ok, strip_metadata(image, resolved)}
    end
  end

  # Kept EXIF still describes the source's colors. Its white point and
  # primaries go, and ColorSpace is sRGB (1) only for an sRGB target, or
  # Uncalibrated (65535), which tells readers to use the profile.
  defp tag_exif_color(image, target) do
    color_space? = header_value(image, "exif-ifd2-ColorSpace") != nil
    color_space = if target == :srgb, do: "1", else: "65535"

    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        VixMutableImage.remove(mut, "exif-ifd0-WhitePoint")
        VixMutableImage.remove(mut, "exif-ifd0-PrimaryChromaticities")

        if color_space?,
          do: VixMutableImage.set(mut, "exif-ifd2-ColorSpace", :gchararray, color_space)

        :ok
      end)

    image
  end

  # Only JPEG can store CMYK pixels; other formats would convert an exported
  # CMYK image back without its profile, so they keep the standard working space.
  defp holds_profile_space?(format, profile)
       when is_binary(profile) and byte_size(profile) >= 128,
       do: binary_part(profile, 16, 4) != "CMYK" or format == :jpeg

  defp holds_profile_space?(_format, _profile), do: true

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

  # Convert tagged images to sRGB or sGrey. Untagged images, and images whose
  # profile is sRGB-equivalent, keep their pixels.
  defp to_standard(image) do
    embedded = header_value(image, "icc-profile-data")

    if is_nil(embedded) or SrgbProfile.equivalent?(embedded) do
      {:ok, image}
    else
      profile = standard_profile(VixImage.interpretation(image))

      case Operation.icc_transform(image, profile,
             embedded: true,
             pcs: pcs(embedded),
             depth: icc_depth(image)
           ) do
        {:ok, image} -> {:ok, image}
        {:error, reason} -> {:error, {:decode, reason}}
      end
    end
  end

  # Output-policy validation rejects named profile conversion with HDR preservation.
  # Dialyzer can't see through Vix's generated Operation typings, so it reports
  # the icc_transform calls as failing; they succeed at runtime.
  @dialyzer {:no_fail_call, convert_from_source: 3, convert_from_srgb: 2}
  defp convert_to_target(image, target, {profile, imported?}) do
    if is_binary(profile) and not imported?,
      do: convert_from_source(image, target, profile),
      else: convert_from_srgb(image, target)
  end

  # A source that kept its profile converts from that profile.
  defp convert_from_source(image, target, profile) do
    with {:ok, image} <- restore_backup(image, profile),
         {:ok, converted} <-
           Operation.icc_transform(image, ColorProfile.path!(target), embedded: true) do
      {:ok, converted}
    else
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # Promote greyscale to three-band sRGB before target conversion. Declare sRGB
  # explicitly because untagged sources have no embedded input profile.
  # colourspace produces 8-bit UCHAR, matching libvips' default output depth.
  defp convert_from_srgb(image, target) do
    with {:ok, srgb} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
         {:ok, converted} <-
           Operation.icc_transform(srgb, ColorProfile.path!(target), input_profile: "sRGB") do
      {:ok, converted}
    else
      {:error, reason} -> {:error, {:decode, reason}}
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
  # even when general metadata stripping is disabled. EXIF requires
  # ColorSpace, and without the field libvips writes it as Uncalibrated
  # (65535). The result is sRGB, so the field is set to sRGB (1) instead.
  @icc_remove_fields [
    "icc-profile-data",
    "exif-ifd0-WhitePoint",
    "exif-ifd0-PrimaryChromaticities"
  ]

  defp maybe_drop_profile(image, true), do: {:ok, image}

  defp maybe_drop_profile(image, false) do
    color_space? = header_value(image, "exif-ifd2-ColorSpace") != nil

    {:ok, image} =
      VixImage.mutate(image, fn mut ->
        Enum.each(@icc_remove_fields, &VixMutableImage.remove(mut, &1))

        if color_space?,
          do: VixMutableImage.set(mut, "exif-ifd2-ColorSpace", :gchararray, "1")

        :ok
      end)

    {:ok, image}
  end

  # Removes the metadata fields a save that keeps EXIF would write, leaving
  # copyright and artist when they're kept. The libvips EXIF writer rebuilds
  # the block from the individual `exif-*` fields, such as GPS, so removing
  # only the serialized `exif-data` blob isn't enough. Without kept EXIF,
  # the save's `keep` option drops the metadata instead (see `keep_token/1`).
  defp strip_metadata(image, %Resolved{} = resolved) do
    cond do
      not resolved.strip_metadata ->
        image

      resolved.keep_copyright ->
        icc = header_value(image, "icc-profile-data")
        {:ok, minimized} = minimize_metadata(image, [:copyright, :artist])
        restore_icc(minimized, icc)

      exif_kept?(resolved) ->
        {:ok, names} = VixImage.header_field_names(image)
        Image.remove_metadata!(image, Enum.filter(names, &String.starts_with?(&1, "exif-")))

      true ->
        image
    end
  end

  # Workaround for `image` 0.72.0: `Image.minimize_metadata/2` parses the whole
  # EXIF block, and `Image.Exif.Decode.date_time/1` raises on a date field it
  # can't parse instead of keeping the raw value: an ArgumentError when the
  # parts aren't integers (such as `2024:01:01 02+02:00:00`), and a
  # FunctionClauseError when the tag is stored as a number rather than text.
  # No upstream fix yet. When it raises, remove all metadata, the kept
  # copyright and artist too: the field values libvips reports can't be
  # written back reliably.
  defp minimize_metadata(image, keep) do
    Image.minimize_metadata(image, keep: keep)
  rescue
    _exception -> Image.remove_metadata(image)
  end

  # libvips writes xres/yres (pixels per millimetre) into JFIF, PNG pHYs, and
  # the EXIF block it rebuilds on save, which is WebP's and AVIF's only carrier.
  defp set_density(image, %Resolved{dpi: nil}), do: image

  defp set_density(image, %Resolved{dpi: dpi}) do
    {:ok, image} = Operation.copy(image, xres: dpi / 25.4, yres: dpi / 25.4)
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

  defp output_format(%Resolved{format: format}) do
    mime_type = Format.mime_type!(format)
    {mime_type, Format.suffix!(mime_type)}
  end
end
