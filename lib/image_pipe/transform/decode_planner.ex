defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode load options for a defunctionalized decode `%Request{}`.

  Decode is always opened with `:sequential` access. Random access is provided
  per-op by `ImagePipe.Transform.Chain` when individual operations require it.

  The planner also computes a format-specific load shrink/scale option for
  large downscales.

  The planner is a pure function: it does not read image metadata itself.
  The caller (`ImagePipe.Decode`) reads the header dims and source format and
  passes them in.
  """

  alias ImagePipe.Transform.DecodePlanner.Request

  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @doc """
  Chooses decode load options from a defunctionalized `%Request{}` (#377/#454).

  Precedence: `trim?` disables shrink; else `resize_target` governs when
  present; else `terminal_reduction` governs (a tiny terminal frame, e.g.
  blurhash, still informs load shrink even with no resize); neither present
  means no shrink from those inputs. `required_extent` independently caps the
  chosen shrink so the loaded display-frame extent never falls below that
  floor.

  A `resize_target`'s axes are each independently optional, and fractional once
  `dpr`/`zoom` inflate them (see `t:Request.resize_target/0`), so
  `ratio_from_targets/4` yields the exact ratio rather than an approximation of
  it.

  The shrink-axis swap is decided by the *net* orientation turn: the EXIF turn
  (`exif_quarter_turn?` and `auto_rotate?`) XOR the request's pre-resize
  rotate (`request.user_quarter_turn?`).
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

    load_shrink =
      request
      |> compute_load_shrink_for_request(shrink_w, shrink_h)
      |> cap_to_required_extent(request.required_extent, shrink_w, shrink_h)

    append_load_option(base, source_format, load_shrink)
  end

  # --- Load shrink from the request ---

  # Trim redefines source dimensions (imgproxy nils ImgData), so any shrink sized
  # against the original would be wrong. Forgo shrink-on-load — declining to
  # shrink is always safe, it forgoes the memory win, never quality.
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

  # `required_extent` is a floor on the *loaded* display-frame extent, not on the
  # extent feeding a resize/terminal target — so it is measured against the (axis-
  # swapped) source dims, independent of any crop, exactly like `load_shrink`
  # itself is bounded from below by 1.0 (never over-shrink past the source).
  defp cap_to_required_extent(load_shrink, nil, _shrink_w, _shrink_h), do: load_shrink

  defp cap_to_required_extent(load_shrink, {required_w, required_h}, shrink_w, shrink_h) do
    floor_ratio = ratio_from_targets(shrink_w, shrink_h, required_w, required_h)
    min(load_shrink, floor_ratio)
  end

  # The resize target is expressed against the *displayed* axes. When the combined
  # net orientation turn (EXIF ∘ user rotate) is a quarter turn, the displayed axes
  # are the stored axes swapped, so we compute the shrink against the swapped axes
  # to avoid picking a factor for the wrong axis.
  defp shrink_axes({w, h}, true), do: {h, w}
  defp shrink_axes(dims, false), do: dims

  # Whether the *combined* net orientation turn applied before the residual resize
  # is a quarter turn (90°/270° mod 180), which transposes the displayed axes. This
  # mirrors imgproxy's `ExtractGeometry`: it swaps the source dims iff
  # `(angle + baseAngle) % 180 != 0`, where `angle` is the EXIF-derived angle (0
  # unless auto-rotate is on) and `baseAngle` is the user `po.Rotate()`
  # (prepare.go:11-22, 270). The EXIF angle contributes a quarter turn iff
  # auto-rotate is enabled *and* the orientation tag is 5/6/7/8 (`exif_quarter_turn?`);
  # 1/2 (0°) and 3/4 (180°) do not. Deferred orientation (#146) folds both into a
  # single pending turn whose `quarter_turn?` predicate the residual resize
  # compensates against, so the shrink-axis swap must agree with that same net turn.
  #
  # The request producer resolves its own pre-resize rotate to a boolean and the
  # two terms combine by XOR — exact,
  # because each term contributes 0 or 90 mod 180 and the sum is a quarter turn
  # iff exactly one of them is. A request without rotation before resize
  # leaves `user_quarter_turn?` at `false`, collapsing this to the EXIF term alone.
  defp request_net_quarter_turn?(
         %Request{user_quarter_turn?: user_turn?},
         exif_qt?,
         auto_rotate?
       ),
       do: (exif_qt? and auto_rotate?) != user_turn?

  # `src / target` per axis, taking the tighter (larger) ratio when both axes have
  # a target (never over-shrink past either constraint), a single axis's ratio when
  # only one target is given, or `1.0` (no shrink) when neither axis has a target.
  #
  # The load shrink must never decode the image *below* the residual resize's
  # target on either axis — otherwise that resize would upscale a shrunk image and
  # produce a softer result than the full-decode path.
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
