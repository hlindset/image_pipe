defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses decode load options from a concrete `%Request{}`.

  Decode is always opened with `:sequential` access. Random access is provided
  by `ImagePipe.Transform.run/3` when an operation requires it.

  The planner computes a format-specific shrink/scale option for downscales.
  It is pure: `ImagePipe.Decode` supplies the header dimensions and source format.
  """

  alias ImagePipe.Transform.DecodePlanner.Request

  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @doc """
  Chooses decode load options from `%Request{}`.

  `trim?` disables shrink. Otherwise, `resize_target` takes precedence over
  `terminal_reduction`; neither present means no shrink. A terminal such as
  blurhash can therefore reduce the decode size even without a resize.

  Target axes are independently optional and may be fractional after `dpr`/`zoom`
  scaling (see `t:Request.resize_target/0`). The planner uses them without rounding.

  Shrink axes swap when exactly one of the enabled EXIF orientation and the
  pre-resize user rotation is a quarter turn.
  """
  @spec open_options_for(
          Request.t(),
          source_format(),
          {pos_integer(), pos_integer()},
          boolean(),
          boolean()
        ) :: keyword()
  def open_options_for(
        %Request{} = request,
        source_format,
        {src_w, src_h},
        exif_quarter_turn? \\ false,
        auto_rotate? \\ false
      )
      when is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and
             is_boolean(exif_quarter_turn?) and is_boolean(auto_rotate?) do
    {shrink_w, shrink_h} =
      shrink_axes(
        {src_w, src_h},
        request_net_quarter_turn?(request, exif_quarter_turn?, auto_rotate?)
      )

    base = [access: :sequential, fail_on: :error]

    load_shrink = compute_load_shrink_for_request(request, shrink_w, shrink_h)

    append_load_option(base, source_format, load_shrink)
  end

  # Trim changes the source extent, so shrinking against the original dimensions
  # could lose detail. Decode at full resolution until the trimmed extent is known.
  defp compute_load_shrink_for_request(%Request{trim?: true}, _shrink_w, _shrink_h), do: 1.0

  defp compute_load_shrink_for_request(
         %Request{resize_target: {target_w, target_h}} = request,
         shrink_w,
         shrink_h
       ) do
    {crop_w, crop_h} = request.crop_extent || {shrink_w, shrink_h}
    ratio_from_targets(crop_w, crop_h, target_w, target_h)
  end

  defp compute_load_shrink_for_request(
         %Request{terminal_reduction: {target_w, target_h}} = request,
         shrink_w,
         shrink_h
       ) do
    {crop_w, crop_h} = request.crop_extent || {shrink_w, shrink_h}
    ratio_from_targets(crop_w, crop_h, target_w, target_h)
  end

  defp compute_load_shrink_for_request(%Request{}, _shrink_w, _shrink_h), do: 1.0

  # Resize targets use display axes; a net quarter turn swaps the storage axes.
  defp shrink_axes({w, h}, true), do: {h, w}
  defp shrink_axes(dims, false), do: dims

  # Each turn contributes 0 or 90 degrees modulo 180, so XOR gives the net axis
  # swap. EXIF contributes only when auto-rotate is enabled and the tag is 5–8.
  # This must agree with PendingOrientation.quarter_turn?/1 at residual resize.
  defp request_net_quarter_turn?(
         %Request{user_quarter_turn?: user_turn?},
         exif_qt?,
         auto_rotate?
       ),
       do: (exif_qt? and auto_rotate?) != user_turn?

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
