defmodule ImagePipe.Transform.InputColorManagement do
  @moduledoc """
  Fixed, data-determined input-conditioning preamble (NOT a `Plan.Operation`):
  imports the embedded ICC profile into a working space before any processing
  step, mirroring imgproxy's `colorspaceToProcessing`. Seeded once by
  `ImagePipe.Transform.Executor`, which passes `supports_hdr?` (resolved in
  the Request/Output boundary from `Plan.Output.hdr` and the output format's HDR
  capability).
  """

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @doc """
  Conditions a decoded image into a working space before any processing step.

  Mirrors imgproxy `colorspaceToProcessing` (`processing/colorspace_to_processing.go`)
  composed with `vips_icc_import_go` (`vips/vips.c`):

  1. Idempotent: a state that already imported (`color_imported?: true`) is
     returned unchanged.
  2. Best-effort Radiance unpack (`rad2float`) for coded HDR sources.
  3. Linear-light (`:VIPS_INTERPRETATION_scRGB`) sources drop the embedded
     profile (no backup recorded, `color_imported?` stays `false`) but are still
     converted to the working space.
  4. Otherwise, when the source carries an importable embedded ICC profile, the
     profile bytes are recorded on `State`, `color_imported?` is set, the profile
     is imported (landing in PCS float), and the result is converted to the
     working space. Sources without an importable profile skip the import (no
     backup, flag stays `false`) but are still converted.

  Color conversion preserves dimensions; `source_dimensions`/`decode_shrink` are
  left untouched. Failures surface as `{:error, {__MODULE__, reason}}`.
  """
  @spec condition(State.t(), keyword()) :: {:ok, State.t()} | {:error, {__MODULE__, term()}}
  def condition(state, opts \\ [])

  def condition(%State{color_imported?: true} = state, _opts), do: {:ok, state}

  def condition(%State{image: image} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)
    interp = VixImage.interpretation(image)
    target = working_space(interp, hdr?)

    with {:ok, image} <- rad2float(image),
         {:ok, state} <- do_condition(state, image, interp, target) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {__MODULE__, reason}}
    end
  end

  # Linear-light: drop the profile (no backup, no flag) but still convert.
  defp do_condition(state, image, :VIPS_INTERPRETATION_scRGB, target) do
    with {:ok, image} <- remove_profile(image),
         {:ok, image} <- to_colorspace(image, target) do
      {:ok, State.set_image(state, image)}
    end
  end

  defp do_condition(state, image, interp, target) do
    profile = profile_data(image)

    if importable?(image, interp, profile) do
      with {:ok, imported} <- icc_import(image, interp, profile),
           {:ok, image} <- to_colorspace(imported, target) do
        {:ok,
         %State{
           State.set_image(state, image)
           | source_color_profile: profile,
             color_imported?: true
         }}
      end
    else
      with {:ok, image} <- to_colorspace(image, target) do
        {:ok, State.set_image(state, image)}
      end
    end
  end

  # Import gating mirrors imgproxy `ImportColourProfile` early-returns: import only
  # when the source has an embedded profile, is not an already-sRGB-IEC61966
  # image, and is in a band layout `vips_icc_import` accepts.
  defp importable?(image, interp, profile) do
    is_binary(profile) and
      not (interp == :VIPS_INTERPRETATION_sRGB and srgb_iec61966?(profile)) and
      coding_none?(image) and band_format_importable?(image)
  end

  # Imports the embedded profile, landing in PCS float. For RGB16/GREY16 sources
  # carrying an alpha band, mirrors `vips_icc_import_go`: split the alpha off,
  # import the color bands only, rescale the 16-bit alpha, and rejoin.
  defp icc_import(image, interp, profile) do
    pcs = pcs(profile)

    case alpha_split(image, interp) do
      {:ok, color, alpha} ->
        with {:ok, imported} <- Operation.icc_import(color, embedded: true, pcs: pcs),
             {:ok, alpha} <- rescale_alpha(alpha, imported) do
          Operation.bandjoin([imported, alpha])
        end

      :none ->
        Operation.icc_import(image, embedded: true, pcs: pcs)

      {:error, _} = err ->
        err
    end
  end

  # Returns {:ok, color_bands, alpha_band} for 16-bit sources with alpha, :none
  # otherwise. RGB16 has 3 color bands, GREY16 has 1.
  defp alpha_split(image, :VIPS_INTERPRETATION_RGB16) do
    alpha_split_at(image, 3)
  end

  defp alpha_split(image, :VIPS_INTERPRETATION_GREY16) do
    alpha_split_at(image, 1)
  end

  defp alpha_split(_image, _interp), do: :none

  defp alpha_split_at(image, color_bands) do
    if VixImage.bands(image) > color_bands do
      with {:ok, color} <- Operation.extract_band(image, 0, n: color_bands),
           {:ok, alpha} <- Operation.extract_band(image, color_bands, n: 1) do
        {:ok, color, alpha}
      end
    else
      :none
    end
  end

  # Mirrors the cast-to-imported-format + linear(1/255) rescale of the 16-bit
  # alpha in `vips_icc_import_go`. Rescales by 1/255 (mirrors vips_icc_import_go).
  defp rescale_alpha(alpha, imported) do
    with {:ok, format} <- VixImage.header_value(imported, "format"),
         {:ok, cast} <- Operation.cast(alpha, format) do
      Operation.linear(cast, [1.0 / 255.0], [0.0])
    end
  end

  @doc """
  Hands `condition/2`'s two `State` fields to the encoder, as private image
  metadata, at the delivery boundary.

  The read-side counterpart of `condition/2`: it is the ONLY writer of the
  `imagepipe-icc-imported` / `imagepipe-icc-backup` headers that
  `ImagePipe.Output.Encoder`'s colorspace-to-result step reads (mirroring
  imgproxy `colorspaceToResult`). It lives here, next to `condition/2`, because
  `condition/2` is the only writer of the `State` fields it carries — the pair
  is one seam, and every caller that runs the preamble must also run this or the
  encoder silently takes the "no import ran" branch on an imported image.

  Call it once per request, after the last operation and before encoding. Both
  in-tree dialects and `ImagePipe.Request.Processor` do.

  A state that never imported (`color_imported?: false`, e.g. a profile-less or
  linear-light source) is returned unchanged: there is nothing to carry.
  """
  @spec stamp_carry(State.t()) :: State.t()
  def stamp_carry(%State{color_imported?: false} = state), do: state

  def stamp_carry(%State{source_color_profile: profile} = state) when is_binary(profile) do
    {:ok, image} =
      VixImage.mutate(state.image, fn mut ->
        :ok = MutableImage.set(mut, "imagepipe-icc-backup", :VipsBlob, profile)
        :ok = MutableImage.set(mut, "imagepipe-icc-imported", :gint, 1)
      end)

    State.set_image(state, image)
  end

  def stamp_carry(%State{} = state), do: state

  defp to_colorspace(image, target), do: Operation.colourspace(image, target)

  # Best-effort: only Radiance-coded sources need unpacking; everything else is a
  # pass-through.
  defp rad2float(image) do
    case VixImage.header_value(image, "coding") do
      {:ok, :VIPS_CODING_RAD} -> Operation.rad2float(image)
      _ -> {:ok, image}
    end
  end

  defp remove_profile(image) do
    VixImage.mutate(image, fn mutable ->
      _ = MutableImage.remove(mutable, "icc-profile-data")
      :ok
    end)
  end

  defp profile_data(image) do
    case VixImage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) -> profile
      _ -> nil
    end
  end

  defp coding_none?(image) do
    VixImage.header_value(image, "coding") == {:ok, :VIPS_CODING_NONE}
  end

  defp band_format_importable?(image) do
    case VixImage.header_value(image, "format") do
      {:ok, :VIPS_FORMAT_UCHAR} -> true
      {:ok, :VIPS_FORMAT_USHORT} -> true
      _ -> false
    end
  end

  @doc "Working-space interpretation for a decoded image (port of guessTargetColorspace)."
  @spec working_space(atom(), boolean()) :: atom()
  def working_space(interpretation, supports_hdr?)

  def working_space(:VIPS_INTERPRETATION_sRGB, _hdr), do: :VIPS_INTERPRETATION_sRGB
  def working_space(:VIPS_INTERPRETATION_RGB, _hdr), do: :VIPS_INTERPRETATION_RGB
  def working_space(:VIPS_INTERPRETATION_B_W, _hdr), do: :VIPS_INTERPRETATION_B_W

  def working_space(:VIPS_INTERPRETATION_RGB16, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(:VIPS_INTERPRETATION_RGB16, false), do: :VIPS_INTERPRETATION_sRGB
  def working_space(:VIPS_INTERPRETATION_GREY16, true), do: :VIPS_INTERPRETATION_GREY16
  def working_space(:VIPS_INTERPRETATION_GREY16, false), do: :VIPS_INTERPRETATION_B_W
  def working_space(:VIPS_INTERPRETATION_CMYK, _hdr), do: :VIPS_INTERPRETATION_sRGB
  def working_space(_other, true), do: :VIPS_INTERPRETATION_RGB16
  def working_space(_other, false), do: :VIPS_INTERPRETATION_sRGB

  @doc """
  Reads the Profile Connection Space from bytes 20–23 of the ICC header.
  Returns `:VIPS_PCS_XYZ` when those bytes equal `"XYZ "`, otherwise
  `:VIPS_PCS_LAB`. Profiles shorter than 128 bytes (or `nil`) default to
  `:VIPS_PCS_LAB`.

  Port of `vips_icc_get_pcs` in imgproxy `vips/vips.c`.
  """
  @spec pcs(binary() | nil) :: :VIPS_PCS_XYZ | :VIPS_PCS_LAB
  def pcs(profile) when is_binary(profile) and byte_size(profile) >= 128 do
    case profile do
      <<_::binary-size(20), "XYZ ", _::binary>> -> :VIPS_PCS_XYZ
      _ -> :VIPS_PCS_LAB
    end
  end

  def pcs(_), do: :VIPS_PCS_LAB

  @doc """
  Returns `true` when the ICC profile header matches the canonical sRGB
  IEC61966-2.1 profile as identified by `vips_icc_is_srgb_iec61966` in
  imgproxy `vips/vips.c`.

  Checks (all must match):
  - offset  8 – version `<<2, 16, 0, 0>>` (profile version 2.1)
  - offset 16 – colorspace `"RGB "`
  - offset 24 – creation date `<<7, 206, 0, 2, 0, 9>>` (1998-12-01)
  - offset 48 – device manufacturer `"IEC "`
  - offset 52 – device model `"sRGB"`
  - offset 80 – profile creator `"HP  "`

  Profiles shorter than 128 bytes (or `nil`) return `false`.
  """
  @spec srgb_iec61966?(binary() | nil) :: boolean()
  def srgb_iec61966?(profile) when is_binary(profile) and byte_size(profile) >= 128 do
    match?(
      <<
        _::binary-size(8),
        # offset 8: version 2.1
        2,
        16,
        0,
        0,
        _::binary-size(4),
        # offset 16: colorspace "RGB "
        "RGB ",
        _::binary-size(4),
        # offset 24: date 1998-12-01
        7,
        206,
        0,
        2,
        0,
        9,
        _::binary-size(18),
        # offset 48: device manufacturer "IEC "
        "IEC ",
        # offset 52: device model "sRGB"
        "sRGB",
        _::binary-size(24),
        # offset 80: profile creator "HP  "
        "HP  ",
        _::binary
      >>,
      profile
    )
  end

  def srgb_iec61966?(_), do: false
end
