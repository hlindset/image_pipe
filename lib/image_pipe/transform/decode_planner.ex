defmodule ImagePipe.Transform.DecodePlanner do
  @moduledoc """
  Chooses image decode load options for semantic Plan operations.

  Decode is always opened with `:sequential` access. Random access is provided
  per-op by `ImagePipe.Transform.Chain` when individual operations require it.

  The planner also computes a format-specific load shrink/scale option for
  large downscales.

  The planner is a pure function: it does not read image metadata itself.
  The caller (Request.Processor) reads the header dims and source format and
  passes them in.
  """

  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Resize, as: PlanResize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Trim, as: PlanTrim
  alias ImagePipe.Transform.DecodePlanner.Request

  @type source_format() ::
          :jpeg | :webp | :png | :tiff | :jpeg2000 | :jpeg_xl | :heif | :avif | atom()

  @spec open_options(
          [ImagePipe.Plan.Pipeline.operation()],
          source_format(),
          {pos_integer(), pos_integer()},
          boolean(),
          boolean()
        ) ::
          keyword()
  def open_options(
        chain,
        source_format,
        {src_w, src_h},
        exif_quarter_turn? \\ false,
        auto_rotate? \\ false
      )
      when is_list(chain) and is_atom(source_format) and
             is_integer(src_w) and src_w > 0 and
             is_integer(src_h) and src_h > 0 and
             is_boolean(exif_quarter_turn?) and is_boolean(auto_rotate?) do
    {shrink_w, shrink_h} =
      shrink_axes({src_w, src_h}, net_quarter_turn?(chain, exif_quarter_turn?, auto_rotate?))

    base = [access: :sequential, fail_on: :error]
    load_shrink = compute_load_shrink(chain, shrink_w, shrink_h)
    append_load_option(base, source_format, load_shrink)
  end

  @doc """
  Chooses decode load options from a defunctionalized `%Request{}` instead of a
  semantic op chain (#377/#454).

  Same base access options and the same jpeg `shrink:`/webp `scale:` math as
  `open_options/5`, computed from resolved display-frame extents rather than
  walking a `Plan.Pipeline` chain. Precedence: `trim?` disables shrink; else
  `resize_target` governs when present; else `terminal_reduction` governs (a
  tiny terminal frame, e.g. blurhash, still informs load shrink even with no
  resize); neither present means no shrink from those inputs.
  `required_extent` independently caps the chosen shrink so the loaded
  display-frame extent never falls below that floor.

  The shrink-axis swap is decided by the same *net* turn `open_options/5`
  computes from the chain: the EXIF turn (`exif_quarter_turn?` and
  `auto_rotate?`) XOR the dialect's own pre-resize rotate
  (`request.user_quarter_turn?`).
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

  # --- Request-based shrink computation (mirrors compute_load_shrink/3) ---

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
         %Request{terminal_reduction: {target_w, target_h}},
         shrink_w,
         shrink_h
       ) do
    ratio_from_targets(shrink_w, shrink_h, target_w, target_h)
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
  # 1/2 (0°) and 3/4 (180°) do not. The user contribution is the sum of `%Rotate{}`
  # angles before the first resize. Deferred orientation (#146) folds both into a
  # single pending turn whose `quarter_turn?` predicate the residual resize
  # compensates against, so the shrink-axis swap must agree with that same net turn.
  defp net_quarter_turn?(chain, exif_quarter_turn?, auto_rotate?) do
    exif_angle = if auto_rotate? and exif_quarter_turn?, do: 90, else: 0
    rem(exif_angle + user_rotate_angle_before_resize(chain), 180) == 90
  end

  # The `%Request{}` form of `net_quarter_turn?/3` above. A defunctionalized
  # request has no chain to walk, so the dialect resolves its own pre-resize
  # rotate to a boolean and the two terms combine by XOR — exact, because each
  # term contributes 0 or 90 mod 180 and the sum is a quarter turn iff exactly
  # one of them is. A dialect that emits no rotate before its resize leaves
  # `user_quarter_turn?` at `false`, collapsing this to the EXIF term alone.
  defp request_net_quarter_turn?(
         %Request{user_quarter_turn?: user_turn?},
         exif_qt?,
         auto_rotate?
       ),
       do: (exif_qt? and auto_rotate?) != user_turn?

  # Sum of user `%Rotate{}` angles reaching the chain before the first resize,
  # reduced mod 360. A 180° rotate contributes no axis swap; two quarter turns
  # cancel; the canonical pipeline order (rotate → crop → resize) places all user
  # rotates before the resize, so this matches the pending orientation the resize
  # sees when it runs.
  defp user_rotate_angle_before_resize(chain) do
    Enum.reduce_while(chain, 0, fn
      %Rotate{angle: angle}, acc -> {:cont, rem(acc + angle, 360)}
      %PlanResize{}, acc -> {:halt, acc}
      _operation, acc -> {:cont, acc}
    end)
  end

  # --- Shrink/scale computation ---

  # The load shrink must never decode the image *below* the residual resize's
  # target on either axis — otherwise that resize would upscale a shrunk image and
  # produce a softer result than the full-decode path. We therefore compute the
  # shrink against the residual resize's *effective* target, which `dpr` and `zoom`
  # inflate.
  #
  # A crop reaching the chain before the resize is allowed through (imgproxy
  # parity, #151): the crop reduces the pixels feeding the resize, so the shrink is
  # sized against the *cropped* extent — `min(crop_dim, src_dim)` per axis, mirroring
  # imgproxy's `widthToScale = MinNonZero(CropWidth, SrcWidth)` (prepare.go:275-278)
  # — never the full source, which would over-shrink the cropped region. The crop's
  # absolute pixel dims and gravity offsets are rescaled by the realized shrink at
  # execution time (Executor); relative (ratio/percent/focus-point) crops shrink
  # in place and need no coordinate rescale.
  #
  # A quarter-turn rotate reaching the chain before the resize is also allowed
  # through (#151): orientation is deferred (#146) and flushed *after* the residual
  # resize, so the stored axes still feed the resize; the only adjustment is that
  # the resize target is expressed against the *displayed* axes, which `shrink_axes`
  # already swaps when the combined net turn (EXIF ∘ user rotate) is a quarter turn.
  # The realized shrink scalar is unchanged by a rotate, so B1's crop-coordinate
  # rescale at execution still applies verbatim.
  #
  # `min_width`/`min_height` remain ineligible — they enlarge the result to a floor,
  # interacting with aspect ratio in ways that are not a simple per-axis multiplier;
  # `resize_load_shrink/3` returns `1.0` for that shape, so it never shrinks.
  #
  # Declining to shrink is always safe — it forgoes the memory win, never quality.
  #
  # The shrink is driven by the first resize sized against the extent that actually
  # feeds it: a preceding crop narrows that extent (per axis) to the cropped size.
  defp compute_load_shrink(chain, src_w, src_h) do
    if Enum.any?(chain, &match?(%PlanTrim{}, &1)) do
      # Trim redefines source dimensions (imgproxy nils ImgData), so any shrink
      # sized against the original would be wrong. Forgo shrink-on-load — only
      # affects the first pipeline, matching imgproxy (trim disables scaleOnLoad).
      1.0
    else
      {crop_w, crop_h} = crop_extent_before_resize(chain, src_w, src_h)

      case Enum.find(chain, &match?(%PlanResize{}, &1)) do
        nil -> 1.0
        resize -> resize_load_shrink(resize, crop_w, crop_h)
      end
    end
  end

  # The extent feeding the first resize, per axis: the cropped dimension when a
  # crop precedes the resize, else the full source dimension. Mirrors imgproxy's
  # `widthToScale = MinNonZero(CropWidth, SrcWidth)` (prepare.go:275-276). Absolute
  # pixel crops clamp to the source; relative crops scale the source; `:full_axis`
  # leaves the axis at full source extent.
  #
  # The canonical pipeline (orientation → crop → resize → …) has at most ONE crop
  # before the resize, so we halt at the first crop and ignore any later one: a
  # cover/auto result-crop is emitted AFTER the resize, never before it. There is
  # no multi-crop-before-resize shape to accumulate.
  defp crop_extent_before_resize(chain, src_w, src_h) do
    Enum.reduce_while(chain, {src_w, src_h}, fn
      %CropGuided{width: cw, height: ch}, _acc ->
        {:halt, {crop_axis_extent(cw, src_w), crop_axis_extent(ch, src_h)}}

      %CropRegion{width: cw, height: ch}, _acc ->
        {:halt, {crop_axis_extent(cw, src_w), crop_axis_extent(ch, src_h)}}

      %PlanResize{}, acc ->
        {:halt, acc}

      _operation, acc ->
        {:cont, acc}
    end)
  end

  defp crop_axis_extent(:full_axis, src), do: src
  defp crop_axis_extent({:px, n}, src) when n > 0, do: min(n, src)

  defp crop_axis_extent({:ratio, num, den}, src) when num > 0 and den > 0,
    do: min(src, max(1, round(src * num / den)))

  defp resize_load_shrink(%PlanResize{min_width: mw, min_height: mh}, _src_w, _src_h)
       when not is_nil(mw) or not is_nil(mh),
       do: 1.0

  defp resize_load_shrink(%PlanResize{width: width, height: height} = resize, src_w, src_h) do
    target_w = px_target_extent(width, resize, :x)
    target_h = px_target_extent(height, resize, :y)
    ratio_from_targets(src_w, src_h, target_w, target_h)
  end

  defp px_target_extent({:px, n}, resize, axis) when n > 0, do: target_extent(n, resize, axis)
  defp px_target_extent(_dimension, _resize, _axis), do: nil

  # Shared ratio math for both entry points: `src / target` per axis, taking the
  # tighter (larger) ratio when both axes have a target (never over-shrink past
  # either constraint), a single axis's ratio when only one target is given, or
  # `1.0` (no shrink) when neither axis has a target.
  defp ratio_from_targets(_src_w, _src_h, nil, nil), do: 1.0
  defp ratio_from_targets(src_w, _src_h, target_w, nil), do: src_w / target_w
  defp ratio_from_targets(_src_w, src_h, nil, target_h), do: src_h / target_h

  defp ratio_from_targets(src_w, src_h, target_w, target_h),
    do: min(src_w / target_w, src_h / target_h)

  # The residual resize inflates the requested pixel extent by `dpr` (both axes)
  # and `zoom` (per axis). Using the requested (uninflated-by-clamping) dpr is the
  # safe direction: if the resize later clamps dpr down to fit the source, the real
  # target is smaller, so this only ever under-shrinks.
  defp target_extent(dim, %PlanResize{dpr: {:ratio, n, d}, zoom_x: zoom_x}, :x),
    do: dim * (n / d) * zoom_factor(zoom_x)

  defp target_extent(dim, %PlanResize{dpr: {:ratio, n, d}, zoom_y: zoom_y}, :y),
    do: dim * (n / d) * zoom_factor(zoom_y)

  # A ratio zoom collapses to its float value here: this over-estimates the residual
  # target only to bound the shrink-on-load factor, so exactness is not required.
  defp zoom_factor({:ratio, n, d}), do: n / d
  defp zoom_factor(factor), do: factor

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
