defmodule ImagePipe.SrgbProfile do
  # Recognises embedded RGB profiles that describe sRGB closely enough to treat
  # the image as untagged. Most web images embed one (vendor sRGB profiles and
  # compact variants), and converting through it costs a LittleCMS transform
  # each time while changing at most 1 level in a few channel values.
  #
  # A profile is checked once: a lattice of 8-bit sRGB colors goes through it
  # in both directions, and it is equivalent when no value moves by more than
  # 1 level. The answer is cached in `:persistent_term` by the profile's digest.
  # Profiles come from untrusted sources, so after `@cap` distinct profiles a
  # new one is checked on every use instead of cached. That keeps the answer,
  # and so the output, independent of which profiles the node saw first.
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @cap 256
  @count_key {__MODULE__, :count}

  @doc "Whether `profile` is an RGB profile equivalent to sRGB."
  @spec equivalent?(binary()) :: boolean()
  def equivalent?(<<_::binary-size(16), "RGB ", _::binary-size(108), _::binary>> = profile) do
    key = {__MODULE__, :crypto.hash(:sha256, profile)}

    case :persistent_term.get(key, nil) do
      nil -> check_and_store(key, profile)
      answer -> answer
    end
  end

  def equivalent?(_profile), do: false

  defp check_and_store(key, profile) do
    count = counter()
    answer = check(profile)

    if :counters.get(count, 1) < @cap do
      :counters.add(count, 1, 1)
      :persistent_term.put(key, answer)
    end

    answer
  end

  defp counter do
    case :persistent_term.get(@count_key, nil) do
      nil ->
        count = :counters.new(1, [:write_concurrency])
        :persistent_term.put(@count_key, count)
        count

      count ->
        count
    end
  end

  # Every color on a 16-level lattice, including 255.
  @lattice for r <- Enum.map(0..16, &min(&1 * 16, 255)),
               g <- Enum.map(0..16, &min(&1 * 16, 255)),
               b <- Enum.map(0..16, &min(&1 * 16, 255)),
               into: <<>>,
               do: <<r, g, b>>
  @lattice_width div(byte_size(@lattice), 3)

  # Dialyzer can't see through Vix's generated Operation typings, so it reports
  # the icc calls as failing, and the comparison after them as unreachable.
  # They succeed at runtime.
  @dialyzer {:nowarn_function, check: 1, close?: 1, within_one?: 2}

  defp check(profile) do
    with {:ok, lattice} <-
           VipsImage.new_from_binary(@lattice, @lattice_width, 1, 3, :VIPS_FORMAT_UCHAR),
         {:ok, lattice} <- Operation.copy(lattice, interpretation: :VIPS_INTERPRETATION_sRGB),
         {:ok, tagged} <- with_profile(lattice, profile),
         {:ok, to_srgb} <- Operation.icc_transform(tagged, "sRGB", embedded: true, depth: 8),
         {:ok, imported} <- Operation.icc_import(lattice, input_profile: "sRGB"),
         {:ok, imported} <- with_profile(imported, profile),
         {:ok, from_srgb} <- Operation.icc_export(imported, depth: 8) do
      close?(to_srgb) and close?(from_srgb)
    else
      {:error, _reason} -> false
    end
  end

  defp with_profile(image, profile) do
    VipsImage.mutate(image, fn mutable ->
      MutableImage.set(mutable, "icc-profile-data", :VipsBlob, profile)
    end)
  end

  defp close?(image) do
    VipsImage.bands(image) == 3 and VipsImage.format(image) == :VIPS_FORMAT_UCHAR and
      case VipsImage.write_to_binary(image) do
        {:ok, bytes} -> within_one?(bytes, @lattice)
        {:error, _reason} -> false
      end
  end

  defp within_one?(<<a, rest_a::binary>>, <<b, rest_b::binary>>) when abs(a - b) <= 1,
    do: within_one?(rest_a, rest_b)

  defp within_one?(<<>>, <<>>), do: true
  defp within_one?(_bytes, _lattice), do: false
end
