defmodule ImagePipe.Transform.DecodePlanner do
  # Chooses decode open options from a decode extent and resize target.
  #
  # Decode is always opened with `:sequential` access. Random access is provided
  # by `ImagePipe.Transform.Executor.Step.run/3` when an operation requires it.
  #
  # The planner computes a format-specific shrink/scale option for downscales.
  # It is pure: `ImagePipe.Decode` supplies the header dimensions and source format.
  @moduledoc false

  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @typedoc """
  A resize target in display-frame pixels. Each axis is optional and may be
  fractional:

    * A single-axis resize (`w:400` with `:auto` height) uses only that axis's
      ratio. Synthesizing the other axis can over-constrain the shrink.
    * `dpr`/`zoom` can produce fractional targets. Rounding changes the ratio
      and can turn a sub-pixel target into zero.
  """
  @type target() :: {number() | nil, number() | nil}

  @doc """
  Chooses decode open options for decoding `extent` (display-frame pixels)
  down to `target`. `nil` target means no shrink.
  """
  @spec open_options(source_format(), {pos_integer(), pos_integer()}, target() | nil) ::
          keyword()
  # The guards state the domain: a zero or negative extent would otherwise give a
  # ratio at or below 1 and silently decode at full size.
  def open_options(source_format, {width, height}, target)
      when is_atom(source_format) and is_integer(width) and width > 0 and
             is_integer(height) and height > 0 do
    load_shrink =
      case target do
        nil -> 1.0
        {target_w, target_h} -> ratio_from_targets(width, height, target_w, target_h)
      end

    append_load_option([access: :sequential, fail_on: :error], source_format, load_shrink)
  end

  # Use the smaller src/target ratio so neither decoded axis falls below its
  # resize target. Over-shrinking would force an upscale and soften the result.
  # A single target uses its own ratio; no targets means no shrink.
  defp ratio_from_targets(_src_w, _src_h, nil, nil), do: 1.0
  defp ratio_from_targets(src_w, _src_h, target_w, nil), do: src_w / target_w
  defp ratio_from_targets(_src_w, src_h, nil, target_h), do: src_h / target_h

  defp ratio_from_targets(src_w, src_h, target_w, target_h),
    do: min(src_w / target_w, src_h / target_h)

  # Append the format-appropriate load option when load_shrink > 1.
  defp append_load_option(base, :jpeg, load_shrink) do
    n = jpeg_shrink_n(load_shrink)
    if n >= 2, do: base ++ [shrink: n], else: base
  end

  defp append_load_option(base, format, load_shrink) when format in [:webp] do
    if load_shrink > 1.0, do: base ++ [scale: 1.0 / load_shrink], else: base
  end

  defp append_load_option(base, _format, _load_shrink), do: base

  # JPEG block-level IDCT shrink factors: largest power-of-2 in {1,2,4,8} ≤ load_shrink.
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 8, do: 8
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 4, do: 4
  defp jpeg_shrink_n(load_shrink) when load_shrink >= 2, do: 2
  defp jpeg_shrink_n(_), do: 1
end
