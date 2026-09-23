defmodule ImagePipe.Transform.InputColorManagement do
  @moduledoc """
  Converts decoded input to a working color space before transforms.

  Runs once per execution, importing embedded ICC profiles when needed. The
  caller supplies `supports_hdr?` from `ImagePipe.Output.Policy`, based on the HDR
  policy and output format's capabilities.
  """

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @doc """
  Conditions a decoded image into a working space before any processing step.

  1. Returns already-imported state (`color_imported?: true`) unchanged.
  2. Unpacks Radiance-coded HDR input with `rad2float`.
  3. For linear-light (`:VIPS_INTERPRETATION_scRGB`) input, drops the embedded
     profile without saving it or setting `color_imported?`.
  4. For other input with an importable ICC profile, saves the profile bytes on
     `State`, imports to PCS float, and sets `color_imported?`.
  5. Converts to the working space, including when no profile was imported.

  Preserves dimensions, `source_dimensions`, and `decode_shrink`. Returns failures
  as `{:error, {__MODULE__, reason}}`.

  Emits `[:transform, :input_color_management]` through `state.telemetry_opts`,
  with stop metadata `%{result:, working_space:, imported?:}`. Skipped imports
  report `imported?: false`; the already-imported early return emits no span.
  """
  @spec condition(State.t(), keyword()) :: {:ok, State.t()} | {:error, {__MODULE__, term()}}
  def condition(state, opts \\ [])

  def condition(%State{color_imported?: true} = state, _opts), do: {:ok, state}

  def condition(%State{image: image} = state, opts) do
    hdr? = Keyword.get(opts, :supports_hdr?, false)
    interp = VixImage.interpretation(image)
    target = working_space(interp, hdr?)

    Telemetry.span(state.telemetry_opts, [:transform, :input_color_management], %{}, fn ->
      result =
        with {:ok, image} <- rad2float(image),
             {:ok, new_state} <- do_condition(state, image, interp, target) do
          {:ok, new_state}
        else
          {:error, reason} -> {:error, {__MODULE__, reason}}
        end

      {result, condition_stop_metadata(result, target)}
    end)
  end

  defp condition_stop_metadata({:ok, %State{color_imported?: imported?}}, working_space),
    do: %{result: :ok, working_space: working_space, imported?: imported?}

  defp condition_stop_metadata({:error, _reason}, working_space),
    do: %{result: :processing_error, working_space: working_space, imported?: false}

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

  # Import supported uncoded input with an embedded profile, except sRGB input
  # already using the canonical IEC61966 profile.
  defp importable?(image, interp, profile) do
    is_binary(profile) and
      not (interp == :VIPS_INTERPRETATION_sRGB and srgb_iec61966?(profile)) and
      coding_none?(image) and band_format_importable?(image)
  end

  # Import to PCS float. For RGB16/GREY16, separate alpha before importing color
  # bands, then rescale and rejoin it (matching imgproxy's vips_icc_import_go).
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

  # Match vips_icc_import_go: cast alpha to the imported format and scale by 1/255.
  defp rescale_alpha(alpha, imported) do
    with {:ok, format} <- VixImage.header_value(imported, "format"),
         {:ok, cast} <- Operation.cast(alpha, format) do
      Operation.linear(cast, [1.0 / 255.0], [0.0])
    end
  end

  defp to_colorspace(image, target), do: Operation.colourspace(image, target)

  # Only Radiance-coded sources need unpacking.
  defp rad2float(image) do
    case VixImage.header_value(image, "coding") do
      {:ok, :VIPS_CODING_RAD} -> Operation.rad2float(image)
      _ -> {:ok, image}
    end
  end

  defp remove_profile(image) do
    case profile_data(image) do
      nil ->
        {:ok, image}

      _profile ->
        VixImage.mutate(image, fn mutable ->
          _ = MutableImage.remove(mutable, "icc-profile-data")
          :ok
        end)
    end
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

  @doc "Returns the working-space interpretation for the input and output HDR capability."
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
  - offset 24 – creation date prefix `<<7, 206, 0, 2, 0, 9>>`
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
        # offset 24: creation date prefix
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
