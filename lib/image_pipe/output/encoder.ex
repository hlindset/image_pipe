defmodule ImagePipe.Output.Encoder do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.ColorProfile
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Color
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage, as: VixMutableImage
  alias Vix.Vips.Operation

  # Private image fields the delivery-boundary stamp writes
  # (`Request.Processor.materialize_for_delivery/2`) for the color finalize to
  # consume. Removed here once consumed so they never reach the encoded output.
  @private_color_fields ["imagepipe-icc-backup", "imagepipe-icc-imported"]

  @doc """
  The output encoder's hard per-format limits, used by `ImagePipe.Output.Clamp`
  to keep encoding from failing. `:max_dimension` is the hard per-axis pixel
  limit; `:max_pixels` is a total-resolution budget. `:infinity` means no
  practical limit. Sourced from libvips encoder constraints (cf. imgproxy
  `processing/fix_size.go`). #165 folds these with the host `max_result_*` caps
  via `min/2` at the producer before calling `Clamp.clamp/3`.
  """
  @spec encoder_limit(Format.output_format()) :: %{
          max_dimension: pos_integer() | :infinity,
          max_pixels: pos_integer() | :infinity
        }
  def encoder_limit(:webp), do: %{max_dimension: 16_383, max_pixels: :infinity}
  def encoder_limit(:avif), do: %{max_dimension: 16_384, max_pixels: :infinity}
  def encoder_limit(:jpeg), do: %{max_dimension: 65_535, max_pixels: :infinity}
  def encoder_limit(:png), do: %{max_dimension: :infinity, max_pixels: :infinity}

  @spec stream_output(VixImage.t(), Resolved.t(), keyword()) ::
          {:ok, Enumerable.t(), String.t()}
          | {:error, {:encode, Exception.t(), list()}}
          | {:error, {:decode, term()}}
  def stream_output(%VixImage{} = image, %Resolved{} = resolved_output, opts) do
    with {:ok, mime_type, suffix} <- output_format(resolved_output),
         {:ok, finalized} <- finalize(image, resolved_output) do
      image_module = Keyword.get(opts, :image_module, Image)
      stream = image_module.stream!(finalized, output_options(suffix, resolved_output))
      {:ok, stream, mime_type}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
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
    with {:ok, _mime_type, suffix} <- output_format(resolved_output),
         {:ok, binary} <- Image.write(image, :memory, suffix: suffix, quality: quality) do
      {:ok, binary}
    else
      {:error, {:encode, _exception, _stack} = tagged} -> {:error, tagged}
      {:error, reason} -> {:error, {:encode, encode_error(reason), []}}
    end
  rescue
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  end

  defp encode_error(reason),
    do: ArgumentError.exception("failed to encode to buffer: #{inspect(reason)}")

  # Color finalize (port of imgproxy `colorspaceToResult`) + metadata strip.
  # We realize ONCE via copy_memory here, in the producer's own call stack, so a
  # corrupt-source failure is a returnable {:error, ...} (mapped to a 415 decode
  # error) instead of the uncatchable producer crash that an in-`mutate`
  # copy_memory (linked MutableImage GenServer) would cause. All subsequent color
  # work and mutates run on the in-memory image and cannot fail that way.
  defp finalize(image, %Resolved{} = resolved) do
    case VixImage.copy_memory(image) do
      {:ok, mem} ->
        with {:ok, flattened} <- flatten_for_format(mem, resolved) do
          color_result(flattened, resolved)
        end

      {:error, reason} ->
        {:error, {:decode, reason}}
    end
  end

  # imgproxy `flatten` (end of the processing pipeline, before `colorspaceToResult`):
  # when the result format can't carry alpha, composite the alpha-bearing working
  # image onto the resolved `flatten_background` (`Plan.Output.flatten_background`,
  # default opaque white = imgproxy `color.White`) so the encoder never hands an
  # alpha band to a non-alpha save (`jpegsave` rejects it / silently drops it).
  # Guarded by `has_alpha?` so a per-request background (already flattened in the
  # transform chain) and any opaque image pass through untouched. The background's
  # own alpha is intentionally ignored (`to_rgb_list` drops it): the composite
  # target is opaque, matching imgproxy's RGB-only `color.White`.
  defp flatten_for_format(image, %Resolved{format: format, flatten_background: background}) do
    if Format.supports_alpha?(format) or not Image.has_alpha?(image) do
      {:ok, image}
    else
      case Image.flatten(image, background_color: Color.to_rgb_list(background)) do
        {:ok, flattened} -> {:ok, flattened}
        {:error, reason} -> {:error, {:encode, flatten_error(reason), []}}
      end
    end
  end

  defp flatten_error(reason),
    do:
      ArgumentError.exception("failed to flatten alpha for non-alpha output: #{inspect(reason)}")

  # imgproxy `colorspaceToResult`: read the import carry, restore the backed-up
  # source profile (icc_export targets the EMBEDDED profile, so the source blob
  # must be on icc-profile-data first), then switch on (keep?, imported):
  #
  #   keep && imported  -> icc_export to the source profile (re-embed scp:0)
  #   !keep && !imported -> icc_transform to the standard space (sRGB/sGrey)
  #   otherwise          -> nothing (already in the right space)
  #
  # then drop the profile when !keep, and finally strip other metadata and the two
  # private carry fields. The read-before-strip order is load-bearing:
  # `minimize_metadata` enumerate-removes every header field, the private ones
  # included.
  # cp/icc: convert the working-space image (sRGB after the #124 import preamble) to
  # the chosen built-in target profile and embed it. A dedicated clause: it must NOT
  # flow through maybe_drop_profile/2, which (keep? == false here) would strip the
  # profile we just embedded. strip_metadata_and_private preserves the ICC because
  # color_profile is not :strip, while still stripping EXIF/XMP/IPTC.
  defp color_result(image, %Resolved{color_profile: {:convert, target}} = resolved) do
    with {:ok, image} <- convert_to_target(image, target, resolved.format) do
      {:ok, strip_metadata_and_private(image, resolved)}
    end
  end

  defp color_result(image, %Resolved{} = resolved) do
    imported = header_value(image, "imagepipe-icc-imported") == 1
    backup = header_value(image, "imagepipe-icc-backup")

    keep? =
      resolved.color_profile == :preserve_source and
        Format.supports_color_profile?(resolved.format)

    with {:ok, image} <- restore_backup(image, backup),
         {:ok, image} <- apply_color_result(image, keep?, imported),
         {:ok, image} <- maybe_drop_profile(image, keep?) do
      {:ok, strip_metadata_and_private(image, resolved)}
    end
  end

  # keep && imported: re-embed the source profile via icc_export. PCS re-sniffed
  # from the restored profile (same blob as import → matches), depth from the
  # interpretation (icc_export has no embedded-blob target).
  defp apply_color_result(image, true, true) do
    case Operation.icc_export(image,
           pcs: pcs(header_value(image, "icc-profile-data")),
           depth: icc_depth(image)
         ) do
      {:ok, image} -> {:ok, image}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  # !keep && !imported: transform to the standard space. Short-circuits to a no-op
  # for an untagged/already-sRGB image (mirroring imgproxy `has_embedded_icc == 0`).
  defp apply_color_result(image, false, false), do: to_standard(image)

  # keep && !imported (already in the source space) and !keep && imported (already
  # standard): nothing to do.
  defp apply_color_result(image, _keep?, _imported), do: {:ok, image}

  # Transform to the standard space (sRGB for color, sGrey for greyscale), mirroring
  # `vips_icc_transform_standard`. imgproxy's wrapper early-returns when there is no
  # embedded profile, so an untagged image stays pixel-identical.
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

  # Convert working-space sRGB -> target built-in profile and embed it. Greyscale
  # (B_W/sGrey, 1-band) is first promoted to sRGB so the 3-band target transform is
  # valid (N2). Input is declared as the known working space ("sRGB") rather than
  # embedded: true, because an untagged source has no embedded profile to read (N1).
  # The working-space image reaching here is 8-bit sRGB-family today: the HDR
  # working-space path is inactive (`supports_hdr?` is `false`), and `colourspace`
  # to sRGB collapses to 8-bit UCHAR, so the libvips default depth (8) is correct.
  # 16-bit/HDR working-space handling for a target convert is deferred to #121.
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

  # Local PCS sniff (port of imgproxy `vips_icc_get_pcs`, bytes 20–23). Duplicated
  # here rather than reused from `Transform.InputColorManagement`: the encoder is
  # in the `Output` boundary, which must not depend on `Transform`. Kept byte-
  # identical so import and export agree on the connection space.
  defp pcs(p) when is_binary(p) and byte_size(p) >= 128,
    do: if(binary_part(p, 20, 4) == "XYZ ", do: :VIPS_PCS_XYZ, else: :VIPS_PCS_LAB)

  defp pcs(_), do: :VIPS_PCS_LAB

  # icc_export targets the embedded profile, so restore the backed-up source blob
  # onto icc-profile-data first (no-op when absent), mirroring `RestoreColourProfile`.
  defp restore_backup(image, nil), do: {:ok, image}
  defp restore_backup(image, backup), do: {:ok, set_icc(image, backup)}

  # The fields imgproxy's `vips_icc_remove` removes when it drops the profile
  # (imgproxy `vips/vips.c`). Besides the ICC blob it unconditionally strips three EXIF
  # color-characterization tags — independent of metadata stripping — so they
  # must go here too, on the `!keep_profile` path, even when `strip_metadata` is
  # false. imgproxy's internal `imgproxy-icc-profile` carry has no analogue to
  # remove: ImagePipe's own private carry fields (`@private_color_fields`) are
  # stripped separately in `strip_metadata_and_private/2`.
  @icc_remove_fields [
    "icc-profile-data",
    "exif-ifd0-WhitePoint",
    "exif-ifd0-PrimaryChromaticities",
    "exif-ifd2-ColorSpace"
  ]

  defp maybe_drop_profile(image, true), do: {:ok, image}
  defp maybe_drop_profile(image, false), do: {:ok, remove_fields(image, @icc_remove_fields)}

  # Strip EXIF/XMP/IPTC (keeping copyright/artist iff kcr) and remove the two
  # private carry fields. `minimize_metadata` enumerates and removes ALL metadata
  # header fields — crucially the individual `exif-ifd0-*`/`exif-gps-*` entries,
  # which survive removing just the serialized "exif-data" blob and would otherwise
  # be re-serialized into EXIF on encode (leaking GPS/copyright). It also removes
  # the ICC profile and the private carry fields, so the color switch above must
  # already have run. If minimize_metadata fails (malformed/absent EXIF), fall back
  # to blob removal. When strip_metadata is false only the private carry fields are
  # removed; the color profile decision was already applied.
  defp strip_metadata_and_private(image, %Resolved{strip_metadata: false}),
    do: remove_fields(image, @private_color_fields)

  defp strip_metadata_and_private(image, %Resolved{} = resolved) do
    keep = if resolved.keep_copyright, do: [:copyright, :artist], else: []

    icc =
      if resolved.color_profile == :strip, do: nil, else: header_value(image, "icc-profile-data")

    minimized =
      case Image.minimize_metadata(image, keep: keep) do
        {:ok, stripped} ->
          remove_fields(stripped, @private_color_fields)

        {:error, _} ->
          remove_fields(
            image,
            ["exif-data", "xmp-data", "iptc-data"] ++
              icc_fields(resolved) ++ @private_color_fields
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
