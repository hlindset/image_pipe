defmodule ImagePipe.Output.Ssim2Metric do
  # Thin adapter over the `ssimulacra2` package — the only module that references
  # `Ssimulacra2.*`. `reference/1` precomputes the comparison reference once (from
  # the finalized pre-encode image); the loop calls `score/2` per decoded candidate.
  # Scores are SSIMULACRA2-native (0–100, 100 = identical).
  #
  # An image with an alpha channel is scored over its visible area only (the
  # bounding box of its non-zero alpha), so transparent margins, which every
  # candidate reproduces, don't raise the score.
  @moduledoc false

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  # Workaround for `ssimulacra2` 0.1.0: `Ssimulacra2.Vix` flattens alpha onto
  # black, where edge and alpha-channel errors in dark content don't show. Like
  # libjxl's `ssimulacra2` tool, blend onto dark and light grey and keep the
  # lower score. Upstream issue: beads image_plug-2pf9.
  @backgrounds [0.1, 0.9]

  @opaque ref ::
            Ssimulacra2.Reference.t()
            | {:alpha, window(), [{float(), Ssimulacra2.Reference.t()}]}

  @typep window :: {non_neg_integer(), non_neg_integer(), pos_integer(), pos_integer()}

  @spec reference(VixImage.t()) :: {:ok, ref()} | {:error, term()}
  def reference(%VixImage{} = image) do
    if VixImage.has_alpha?(image) do
      alpha_reference(image)
    else
      Ssimulacra2.Vix.reference(image)
    end
  end

  @spec score(ref(), VixImage.t()) :: {:ok, float()} | {:error, term()}
  def score({:alpha, window, references}, %VixImage{} = candidate) do
    with {:ok, visible} <- crop(candidate, window),
         {:ok, scores} <- map_concurrent(references, &background_score(visible, &1)),
         do: {:ok, Enum.min(scores)}
  end

  def score(reference, %VixImage{} = candidate),
    do: Ssimulacra2.Vix.compare(reference, candidate)

  defp alpha_reference(image) do
    format = if VixImage.format(image) == :VIPS_FORMAT_UCHAR, do: :rgb888, else: :rgb16

    with {:ok, window} <- visible_window(image),
         {:ok, visible} <- crop(image, window),
         {:ok, references} <- background_references(visible, format) do
      {:ok, {:alpha, window, references}}
    end
  end

  defp background_references(visible, format) do
    map_concurrent(@backgrounds, fn background ->
      with {:ok, blended} <- blend(visible, format, background),
           {:ok, reference} <- Ssimulacra2.Vix.reference(blended),
           do: {:ok, {background, reference}}
    end)
  end

  defp background_score(visible, {background, reference}) do
    with {:ok, blended} <- blend(visible, reference.format, background),
         do: Ssimulacra2.Vix.compare(reference, blended)
  end

  # `Enum.map/2` for a function returning `{:ok, value}`, run for every item
  # at once: each background's blend and compare is a native call on its own
  # dirty scheduler. Returns the first error in item order. A raise in an
  # item is raised again here, so the caller's spans see it as before.
  defp map_concurrent(items, fun) do
    items
    |> Task.async_stream(&capture(fun, &1), ordered: true, timeout: :infinity)
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, {:raised, kind, reason, stacktrace}}, _acc -> :erlang.raise(kind, reason, stacktrace)
      {:ok, {:ok, value}}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:ok, error}, _acc -> {:halt, error}
      {:exit, reason}, _acc -> exit(reason)
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp capture(fun, item) do
    fun.(item)
  catch
    kind, reason -> {:raised, kind, reason, __STACKTRACE__}
  end

  # Blend onto a grey `background` (0.0–1.0) in the colour space and bit depth
  # `Ssimulacra2.Vix` scores `format` in, so the blend matches libjxl's, which
  # blends the stored (gamma-encoded) values.
  defp blend(image, :rgb888, background),
    do: blend(image, :VIPS_INTERPRETATION_sRGB, :VIPS_FORMAT_UCHAR, background * 255)

  defp blend(image, :rgb16, background),
    do: blend(image, :VIPS_INTERPRETATION_RGB16, :VIPS_FORMAT_USHORT, background * 65_535)

  defp blend(image, interpretation, band_format, level) do
    with {:ok, colour} <- Operation.colourspace(image, interpretation),
         {:ok, flat} <- flatten(colour, level) do
      Operation.cast(flat, band_format)
    end
  end

  defp flatten(image, level) do
    if VixImage.has_alpha?(image),
      do: Operation.flatten(image, background: [level, level, level]),
      else: {:ok, image}
  end

  # The bounding box of the pixels with non-zero alpha, or the whole frame when
  # none are visible.
  defp visible_window(image) do
    with {:ok, alpha} <- Operation.extract_band(image, VixImage.bands(image) - 1),
         {:ok, visible} <-
           Operation.relational_const(alpha, :VIPS_OPERATION_RELATIONAL_MORE, [0.0]),
         {:ok, {columns, rows}} <- Operation.project(visible),
         {:ok, xs} <- extent(columns),
         {:ok, ys} <- extent(rows) do
      case {xs, ys} do
        {{left, right}, {top, bottom}} ->
          {:ok, {left, top, right - left + 1, bottom - top + 1}}

        _none_visible ->
          {:ok, {0, 0, VixImage.width(image), VixImage.height(image)}}
      end
    end
  end

  # First and last index of a non-zero entry in a one-dimensional projection.
  defp extent(projection) do
    with {:ok, sums} <- Operation.cast(projection, :VIPS_FORMAT_DOUBLE),
         {:ok, binary} <- VixImage.write_to_binary(sums) do
      indexes = for {sum, index} <- Enum.with_index(doubles(binary)), sum > 0, do: index
      {:ok, if(indexes == [], do: nil, else: {List.first(indexes), List.last(indexes)})}
    end
  end

  defp doubles(binary), do: for(<<value::native-float-64 <- binary>>, do: value)

  defp crop(image, {left, top, width, height}) do
    if {left, top, width, height} == {0, 0, VixImage.width(image), VixImage.height(image)},
      do: {:ok, image},
      else: Operation.extract_area(image, left, top, width, height)
  end
end
