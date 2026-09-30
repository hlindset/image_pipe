defmodule ImagePipe.Test.Differential.PixelCompare do
  @moduledoc """
  Pixel comparisons for reference fixtures and orientation tests.
  Operates on decoded `Vix.Vips.Image` structs. Each band is read once
  to a raw row-major buffer (`write_to_binary/1`) and indexed in the BEAM, so a
  full-frame comparison costs two FFI reads instead of per-pixel FFI calls.
  """
  use Boundary, top_level?: true, deps: []

  alias Vix.Vips.Image, as: VipsImage

  @spec dims(VipsImage.t()) :: {pos_integer(), pos_integer()}
  def dims(image), do: {Image.width(image), Image.height(image)}

  defp format_max(:VIPS_FORMAT_USHORT), do: 65_535.0
  defp format_max(:VIPS_FORMAT_SHORT), do: 32_767.0
  defp format_max(:VIPS_FORMAT_UINT), do: 4_294_967_295.0
  defp format_max(_), do: 255.0

  # A band sample's width in the raw `write_to_binary` buffer. USHORT (16-bit)
  # fixtures pack two bytes per sample; everything else the harness compares
  # (8-bit PNG decode) is one byte. Comparing raw *bytes* would split a 16-bit
  # sample into hi/lo halves and judge each as an 8-bit value, so a hair of 16-bit
  # noise reads as a structural blow-out in the low byte (#229) — hence the
  # per-format walk below.
  defp sample_bytes(:VIPS_FORMAT_USHORT), do: 2
  defp sample_bytes(_), do: 1

  # 8-bit-equivalent level → raw sample threshold for this band format, so one
  # tolerance vocabulary (0..255 levels) judges 8- and 16-bit fixtures alike
  # (USHORT: ×257, since 65535/255 = 257).
  defp raw_threshold(level, format), do: round(level * format_max(format) / 255.0)

  @spec same_dims?(VipsImage.t(), VipsImage.t()) :: boolean()
  def same_dims?(a, b), do: dims(a) == dims(b)

  @doc """
  Count of band-samples whose absolute delta exceeds `threshold`, in 8-bit-equivalent
  levels (per-sample counting upper-bounds pixel outliers — the stricter choice). A
  16-bit (USHORT) sample is reconstructed and judged in 16-bit space, then compared
  against `threshold` scaled into that space, so the count is per *sample*, not per
  raw byte. Raises `ArgumentError` if the two images differ in dimensions or band
  layout.
  """
  @spec outliers(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: non_neg_integer()
  def outliers(a, b, threshold) do
    unless same_dims?(a, b) do
      raise ArgumentError, "dimension mismatch: #{inspect(dims(a))} vs #{inspect(dims(b))}"
    end

    {:ok, ab} = VipsImage.write_to_binary(a)
    {:ok, bb} = VipsImage.write_to_binary(b)

    unless byte_size(ab) == byte_size(bb) do
      raise ArgumentError, "band layout mismatch: #{byte_size(ab)} vs #{byte_size(bb)}"
    end

    format = VipsImage.format(a)
    count_outliers(format, ab, bb, raw_threshold(threshold, format), 0)
  end

  @doc """
  Fraction (0.0..1.0) of band-samples whose absolute delta exceeds `threshold` — a
  whole-frame divergence metric. The denominator is the sample count (USHORT bands
  carry one sample per two bytes), matching `outliers/3`. Raises on dimension/band-
  layout mismatch.
  """
  @spec fraction_over(VipsImage.t(), VipsImage.t(), non_neg_integer()) :: float()
  def fraction_over(a, b, threshold) do
    {:ok, ab} = VipsImage.write_to_binary(a)

    case div(byte_size(ab), sample_bytes(VipsImage.format(a))) do
      0 -> 0.0
      samples -> outliers(a, b, threshold) / samples
    end
  end

  # Counts band-samples (not pixels) whose absolute delta exceeds the raw threshold.
  # Per-sample counting upper-bounds pixel outliers — the stricter choice. A USHORT
  # sample is reconstructed from its two native-endian bytes so the delta is judged
  # in 16-bit space, not split across hi/lo bytes (#229).
  defp count_outliers(_format, <<>>, <<>>, _t, acc), do: acc

  defp count_outliers(
         :VIPS_FORMAT_USHORT,
         <<av::native-unsigned-16, ar::binary>>,
         <<bv::native-unsigned-16, br::binary>>,
         t,
         acc
       ) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(:VIPS_FORMAT_USHORT, ar, br, t, acc)
  end

  defp count_outliers(format, <<av, ar::binary>>, <<bv, br::binary>>, t, acc) do
    acc = if abs(av - bv) > t, do: acc + 1, else: acc
    count_outliers(format, ar, br, t, acc)
  end
end
