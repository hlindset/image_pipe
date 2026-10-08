defmodule ImagePipe.Transform.InputColorManagement do
  # Converts decoded input to a working color space before transforms.
  #
  # Runs once per execution. RGB-family and gray sources keep their values and
  # embedded profile; other spaces (CMYK, Lab, …) import their profile. The
  # caller supplies `supports_hdr?` from `ImagePipe.Output.Policy`, based on the HDR
  # policy and output format's capabilities.
  @moduledoc false

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  @unimported [
    :VIPS_INTERPRETATION_sRGB,
    :VIPS_INTERPRETATION_RGB,
    :VIPS_INTERPRETATION_RGB16,
    :VIPS_INTERPRETATION_B_W,
    :VIPS_INTERPRETATION_GREY16
  ]

  @doc """
  Conditions a decoded image into a working space before any processing step.

  1. Returns already-imported state (`color_imported?: true`) unchanged.
  2. Unpacks Radiance-coded HDR input with `rad2float`.
  3. For linear-light (`:VIPS_INTERPRETATION_scRGB`) input, drops the embedded
     profile without saving it or setting `color_imported?`.
  4. For sRGB, RGB, RGB16, B_W and GREY16 input, keeps the pixel values and the
     embedded profile, saving the profile bytes on `State` as a backup for the
     output step without setting `color_imported?`.
  5. For other input with an importable ICC profile, saves the profile bytes on
     `State`, imports to PCS float, and sets `color_imported?`.
  6. Converts to the working space, including when no profile was imported.

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
    with {:ok, state} <- materialize_tagged(State.set_image(state, image)),
         {:ok, image} <- remove_profile(state.image),
         {:ok, image} <- to_colorspace(image, target) do
      {:ok, State.set_image(state, image)}
    end
  end

  # RGB-family and gray sources keep their values: operations work on them as
  # they are, and the output step converts or keeps the profile.
  defp do_condition(state, image, interp, target) when interp in @unimported do
    with {:ok, image} <- to_colorspace(image, target) do
      {:ok, %State{State.set_image(state, image) | source_color_profile: profile_data(image)}}
    end
  end

  defp do_condition(state, image, _interp, target) do
    profile = profile_data(image)

    if importable?(image, profile) do
      # The imported pixels no longer match the embedded profile, so drop it from
      # the image; the backup on `State` is what the output step exports to.
      with {:ok, %State{image: image} = state} <-
             materialize_tagged(State.set_image(state, image)),
           {:ok, imported} <- icc_import(image, profile),
           {:ok, image} <- to_colorspace(imported, target),
           {:ok, image} <- remove_profile(image) do
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

  # Import supported uncoded input with an embedded profile.
  defp importable?(image, profile) do
    is_binary(profile) and coding_none?(image) and band_format_importable?(image)
  end

  # Import to PCS float.
  defp icc_import(image, profile),
    do: Operation.icc_import(image, embedded: true, pcs: pcs(profile))

  defp to_colorspace(image, target), do: Operation.colourspace(image, target)

  # Only Radiance-coded sources need unpacking.
  defp rad2float(image) do
    case VixImage.header_value(image, "coding") do
      {:ok, :VIPS_CODING_RAD} -> Operation.rad2float(image)
      _ -> {:ok, image}
    end
  end

  # Workaround for `image`: removing a profile goes through Vix's mutable
  # image, which copies the image to memory in a linked process, so a corrupt
  # lazy source crashes the request there. Buffer it first, so the failure is
  # a decode error.
  defp materialize_tagged(%State{materialized?: true} = state), do: {:ok, state}

  defp materialize_tagged(%State{image: image} = state) do
    case profile_data(image) do
      nil -> {:ok, state}
      _profile -> Materializer.materialize(state)
    end
  end

  defp remove_profile(image) do
    case profile_data(image) do
      nil ->
        {:ok, image}

      _profile ->
        Image.remove_metadata(image, ["icc-profile-data"])
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
end
