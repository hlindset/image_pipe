defmodule ImagePipe.Transform.WorkingColor do
  # Request colors are sRGB, like CSS. Operations paint them into a working
  # image whose values may be in another space: an embedded profile the source
  # kept (Display P3, Adobe RGB, a gray profile), a gray interpretation, or
  # 16-bit samples. This module maps a color into the working image's values,
  # and converts a whole tagged image into another image's space.
  #
  # Workaround for `image` (0.72, unchanged on main as of 2026-10): colors are
  # resolved here through libvips rather than `Image.Pixel.to_pixel/3`, which
  # maps an sRGB color to a gray image's band as Lab L*/100 scaled to the band
  # range (#808080 becomes 137) where libvips stores gray as relative luminance
  # with the sRGB transfer curve (128). It also ignores embedded profiles.
  @moduledoc false

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @spec neutral?([number()]) :: boolean()
  def neutral?([red, green, blue]), do: red == green and green == blue

  @doc """
  Returns the working image's color-band values for an 8-bit sRGB color,
  without an alpha value.
  """
  @spec values(VipsImage.t(), [0..255]) :: {:ok, [float()]} | {:error, term()}
  def values(image, [_red, _green, _blue] = rgb) do
    with {:ok, pixel} <- Image.new(1, 1, color: rgb),
         {:ok, pixel} <- into_profile(pixel, profile(image), image),
         {:ok, pixel} <- to_space(pixel, VipsImage.interpretation(image)) do
      Operation.getpoint(pixel, 0, 0)
    end
  end

  @doc """
  Converts `image` to `interpretation`. libvips widens 8-bit sRGB to RGB16 by
  256 (with 255 special-cased), so that step scales by 257 instead, matching
  its gray conversion.
  """
  @spec to_space(VipsImage.t(), atom()) :: {:ok, VipsImage.t()} | {:error, term()}
  def to_space(image, :VIPS_INTERPRETATION_RGB16) do
    if VipsImage.format(image) == :VIPS_FORMAT_UCHAR do
      with {:ok, srgb} <- Operation.colourspace(image, :VIPS_INTERPRETATION_sRGB),
           {:ok, scaled} <- Operation.linear(srgb, [257.0], [0.0]),
           {:ok, wide} <- Operation.cast(scaled, :VIPS_FORMAT_USHORT) do
        Operation.copy(wide, interpretation: :VIPS_INTERPRETATION_RGB16)
      end
    else
      Operation.colourspace(image, :VIPS_INTERPRETATION_RGB16)
    end
  end

  def to_space(image, interpretation), do: Operation.colourspace(image, interpretation)

  @doc """
  Converts a tagged image to sRGB (or 16-bit RGB) through its embedded profile
  and drops the profile. Untagged images are returned unchanged.
  """
  @spec to_srgb(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def to_srgb(image) do
    case profile(image) do
      nil ->
        {:ok, image}

      _profile ->
        with {:ok, srgb} <-
               Operation.icc_transform(image, "sRGB", embedded: true, depth: depth(image)) do
          Image.remove_metadata(srgb, ["icc-profile-data"])
        end
    end
  end

  @doc """
  Converts a tagged frame to sRGB like `to_srgb/1` and clears the state's
  source-profile backup, since the frame no longer holds values in the source's
  space. Untagged frames are returned unchanged.
  """
  @spec to_srgb_frame(State.t()) :: {:ok, State.t()} | {:error, term()}
  def to_srgb_frame(%State{image: image} = state) do
    case profile(image) do
      nil ->
        {:ok, state}

      _profile ->
        with {:ok, srgb} <- to_srgb(image) do
          {:ok, %State{State.set_image(state, srgb) | source_color_profile: nil}}
        end
    end
  end

  # Dialyzer can't see through Vix's generated Operation typings, so it reports
  # the icc_import call in export/4 as failing; it succeeds at runtime.
  @dialyzer {:no_fail_call, into_space_of: 2, into_profile: 3}

  @doc """
  Converts an RGB `image` into `frame`'s space: through `frame`'s embedded
  profile when it has one, otherwise to sRGB. An untagged image is sRGB.
  """
  @spec into_space_of(VipsImage.t(), VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def into_space_of(image, frame) do
    case {profile(image), profile(frame)} do
      {nil, nil} -> {:ok, image}
      {_profile, nil} -> to_srgb(image)
      {nil, frame_profile} -> export(image, [input_profile: "sRGB"], frame_profile, frame)
      {_profile, frame_profile} -> export(image, [embedded: true], frame_profile, frame)
    end
  end

  # An sRGB pixel goes through the working image's profile, if it has one.
  defp into_profile(pixel, nil, _image), do: {:ok, pixel}

  defp into_profile(pixel, profile, image),
    do: export(pixel, [input_profile: "sRGB"], profile, image)

  # Import with `import_options`, then export to `profile` at `like`'s depth.
  defp export(image, import_options, profile, like) do
    with {:ok, imported} <- Operation.icc_import(image, import_options),
         {:ok, tagged} <-
           VipsImage.mutate(imported, fn mutable ->
             MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
           end) do
      Operation.icc_export(tagged, depth: depth(like))
    end
  end

  @doc "Whether `image` carries an embedded ICC profile."
  @spec tagged?(VipsImage.t()) :: boolean()
  def tagged?(image), do: profile(image) != nil

  defp profile(image) do
    case VipsImage.header_value(image, "icc-profile-data") do
      {:ok, profile} when is_binary(profile) -> profile
      _absent -> nil
    end
  end

  defp depth(image), do: if(VipsImage.format(image) == :VIPS_FORMAT_USHORT, do: 16, else: 8)
end
