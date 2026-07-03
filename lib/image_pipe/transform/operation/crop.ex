defmodule ImagePipe.Transform.Operation.Crop do
  @moduledoc """
  Represents an executable crop operation that selects a bounded rectangle
  from the current image.

  ## Construct When

  Transform Plan execution may convert semantic Plan operations to this
  executable operation. Parser modules should construct
  `ImagePipe.Plan.Operation.*` through Plan constructors.

  Use `Crop` for resolved visible crop work, coordinate-based crops, and result
  crops that trim an already resized image back to resolved target geometry.
  Parser-specific gravity inheritance belongs in the parser/adapter layer
  before semantic Plan operations are constructed.

  ## Fields

  Required fields:

  - `width`: crop width as a positive length or `:auto`.
  - `height`: crop height as a positive length or `:auto`.
  - `crop_from`: crop source, either `:gravity` or `%{left: left, top: top}`
    with non-negative position lengths.

  Optional fields:

  - `gravity`: `nil`, an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`, or a
    focal point tuple `{:fp, x, y}` where `x` and `y` are normalized `0.0..1.0`
    coordinates.
  - `x_offset`: horizontal offset as a number, `{:pixels, value}`,
    `{:scale, value}`, or `{:scale, numerator, denominator}`. Defaults to `0.0`.
  - `y_offset`: vertical offset using the same units as `x_offset`. Defaults
    to `0.0`.
  - `offset_scale`: multiplier applied to pixel offsets, usually the effective
    DPR used by the preceding resize. Defaults to `1.0`.
  - `center_bias`: `{x_side, y_side}` tie-break for a centered crop with an odd
    extent difference, each `:near` (keep the extra pixel toward the left/top
    origin, matching imgproxy `ShrinkToEven`) or `:far` (toward the right/bottom).
    Defaults to `{:near, :near}`. Only affects `:center` anchor axes; callers that
    crop in a frame that is later reversed (deferred orientation) set the
    reversed axis to `:far` so the kept pixel lands on the intended display side.

  Numeric length units are resolved against the current image dimensions during
  execution. `:auto` crop dimensions resolve to the current image dimension on
  that axis.

  ## Execution Semantics

  `execute/2` crops `ImagePipe.Transform.State.image` and returns a state with
  the cropped image. If coordinate mapping or image cropping fails, execution
  returns `{:error, {__MODULE__, reason}}`.

  For `crop_from: :gravity`, execution resolves crop dimensions against the
  current image, defaulting gravity to center when none is provided. Anchor
  gravity pins the crop to an edge or center. Focal-point gravity centers the
  crop around a normalized current-image point and clamps it into image bounds.

  Result crops are represented as `crop_from: :gravity` with explicit `width`
  and `height`. Pixel offsets are multiplied by `offset_scale`; scale offsets
  are resolved relative to the current image bounds.

  For coordinate crops, `crop_from` is the requested top-left crop position
  before the rectangle is clamped to image bounds. `reject_out_of_bounds` is a
  verdict decided upstream: when `true`, the requested region was found to lie
  wholly outside the source (in the original, pre-decode-shrink frame that
  `ImagePipe.Transform.PlanExecutor` owns), so execution returns
  `{:error, {:bad_request, :region_out_of_bounds}}` without cropping. When
  `false` (the default) a coordinate crop clamps to image bounds as usual. The
  detection lives in the executor rather than here because the original-frame
  dimensions and request coordinates are only available before the shrink
  rescale; a partially overlapping region is never rejected.

  ## Examples

      crop = %ImagePipe.Transform.Operation.Crop{
        width: {:pixels, 300},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:fp, 0.25, 0.75},
        x_offset: {:scale, 0.1},
        y_offset: {:pixels, -12}
      }

  A semantic crop request with focal-point guide may execute as the same kind
  of `Crop` operation. URL grammar and aliases stay in parser documentation.
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  import ImagePipe.Transform.Geometry,
    only: [
      center_origin: 2,
      image_height: 1,
      image_width: 1,
      resolve_dimension: 3,
      resolve_offset: 3,
      resolve_position: 2,
      round_half_away_from_zero: 1,
      round_ties_to_even: 1
    ]

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Focal
  alias ImagePipe.Transform.Focus
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @default_gravity {:anchor, :center, :center}

  # Face-favoring blend weight for `{:smart, :face_assist}` gravity. ImagePipe's
  # documented approximation of imgproxy's `smart_crop_face_detection`, whose
  # exact combination of attention saliency and detected faces is unspecified.
  @face_assist_weight 0.7

  @type length_unit() ::
          integer()
          | float()
          | {:pixels, integer() | float()}
          | {:scale, integer() | float()}
          | {:scale, integer() | float(), integer() | float()}

  @doc """
  The executable operation used by `ImagePipe.Transform.Operation.Crop`.
  """
  defstruct [
    :width,
    :height,
    :crop_from,
    gravity: nil,
    x_offset: 0.0,
    y_offset: 0.0,
    offset_scale: 1.0,
    aspect_ratio: nil,
    enlarge: false,
    reject_out_of_bounds: false,
    center_bias: {:near, :near}
  ]

  @type t :: %__MODULE__{
          width: length_unit() | :auto,
          height: length_unit() | :auto,
          crop_from:
            :gravity
            | %{
                left: length_unit(),
                top: length_unit()
              },
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | :carried
            | :smart
            | {:smart, :face_assist}
            | {:detect,
               {:all, %{optional(:default) => number(), optional(String.t()) => number()}}}
            | {:detect,
               {[String.t()], %{optional(:default) => number(), optional(String.t()) => number()}}}
            | nil,
          x_offset: length_unit() | number(),
          y_offset: length_unit() | number(),
          offset_scale: pos_integer() | float(),
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean(),
          reject_out_of_bounds: boolean(),
          center_bias: {:near | :far, :near | :far}
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :crop

  @doc false
  # Realized crop-box dimensions resolved purely against the given live image
  # dims — the exact box `execute/2` crops to on an image of that size (the crop
  # *position* is excluded; it never affects the box). Mirrors the dimension
  # resolution inside `crop_coordinates`/`smart_crop` so the neutral resolver can
  # advance the source shape without reading the live image.
  @spec resolved_box_dims(t(), pos_integer(), pos_integer()) ::
          {pos_integer(), pos_integer()}
  def resolved_box_dims(%__MODULE__{crop_from: :gravity} = params, image_width, image_height) do
    crop_width = resolve_dimension(params.width, image_width, clamp?: true)
    crop_height = resolve_dimension(params.height, image_height, clamp?: true)

    {crop_width, crop_height} =
      correct_aspect_ratio(
        crop_width,
        crop_height,
        params.aspect_ratio,
        params.enlarge,
        image_width,
        image_height
      )

    {max(1, min(image_width, crop_width)), max(1, min(image_height, crop_height))}
  end

  def resolved_box_dims(%__MODULE__{crop_from: %{}} = params, image_width, image_height) do
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    {resolve_dimension(target_width, image_width, clamp?: true),
     resolve_dimension(target_height, image_height, clamp?: true)}
  end

  @doc false
  # The realized crop rectangle resolved purely against the given live image
  # dims — the exact {left, top, width, height} `execute/2` crops on an image
  # of that size. Defined for concrete-gravity (anchor/fp) and coordinate
  # crops; a :smart/:detect/:carried gravity has no pure rectangle (pixels or
  # a substituted point decide it). Lets a resolver strategy translate a
  # carried point by the realized crop origin without reading the live image.
  @spec resolved_rect(t(), pos_integer(), pos_integer()) ::
          {:ok, %{left: integer(), top: integer(), width: pos_integer(), height: pos_integer()}}
          | {:error, term()}
  def resolved_rect(%__MODULE__{crop_from: :gravity} = params, image_width, image_height) do
    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         crop_width = resolve_dimension(crop.width, image_width, clamp?: true),
         crop_height = resolve_dimension(crop.height, image_height, clamp?: true),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, gravity} <- crop_gravity(default_if_nil(params.gravity, @default_gravity)) do
      offset_scale = crop.offset_scale * 1.0
      x_offset = resolve_offset(default_if_nil(params.x_offset, 0.0), image_width, offset_scale)
      y_offset = resolve_offset(default_if_nil(params.y_offset, 0.0), image_height, offset_scale)

      {:ok,
       gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset,
         params.center_bias
       )}
    end
  end

  def resolved_rect(%__MODULE__{} = params, image_width, image_height) do
    %{left: left_coord, top: top_coord} = params.crop_from
    left_px = resolve_position(left_coord, image_width)
    top_px = resolve_position(top_coord, image_height)

    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height

    # make sure crop is within image bounds
    crop_width = resolve_dimension(target_width, image_width, clamp?: true)
    crop_height = resolve_dimension(target_height, image_height, clamp?: true)

    # figure out the crop anchor from the resolved origin
    center_x = round(left_px + crop_width / 2)
    center_y = round(top_px + crop_height / 2)

    # ...and make sure crop still stays within bounds
    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{gravity: :smart}), do: true
  def requires_materialization?(%__MODULE__{gravity: {:smart, _}}), do: true
  def requires_materialization?(%__MODULE__{gravity: {:detect, _}}), do: true
  def requires_materialization?(%__MODULE__{gravity: :carried}), do: false
  def requires_materialization?(%__MODULE__{}), do: false

  @impl ImagePipe.Transform
  def execute(%__MODULE__{gravity: :smart} = params, %State{} = state) do
    smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
  end

  def execute(%__MODULE__{gravity: {:detect, {spec, weights}}} = params, %State{} = state) do
    detect_crop(params, state, spec, weights)
  end

  def execute(%__MODULE__{gravity: {:smart, :face_assist}} = params, %State{} = state) do
    {module, dopts} = normalize_detector(state.detector)

    if is_nil(module) do
      emit_detect_skipped(["face"], state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      face_assist_crop(params, state, module, dopts)
    end
  end

  # A carried-gravity consumer (TwicPics cover/crop) reads the neutral carried
  # point and resolves it to a focal-point gravity at the libvips boundary; a nil
  # carried point falls back to the center anchor (byte-identical to a plain
  # centered crop).
  def execute(%__MODULE__{gravity: :carried} = params, %State{} = state) do
    case Focus.to_fp(state) do
      nil -> execute(%__MODULE__{params | gravity: {:anchor, :center, :center}}, state)
      {:fp, _x, _y} = fp -> execute(%__MODULE__{params | gravity: fp}, state)
    end
  end

  # A coordinate region the executor found wholly outside the source. Returning the
  # {:bad_request, _} reason unwrapped lets Chain yield {:transform_error,
  # {:bad_request, :region_out_of_bounds}} → 400, the same status path as Resize's
  # :upscale_required (a {__MODULE__, _} wrap would demote it to a generic 422).
  def execute(%__MODULE__{reject_out_of_bounds: true, crop_from: %{}}, %State{}) do
    {:error, {:bad_request, :region_out_of_bounds}}
  end

  def execute(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    case resolved_rect(params, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        crop_image(params, state, {left, top, crop_width, crop_height})

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  defp crop_image(%__MODULE__{} = params, %State{} = state, {left, top, crop_width, crop_height}) do
    case Image.crop(state.image, left, top, crop_width, crop_height) do
      {:ok, cropped_image} ->
        {:ok, set_image(carry_focus_through_crop(state, params, left, top), cropped_image)}

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
  end

  # Every crop is a geometry transformer for a carried focus: the focus translates
  # by the realized (clamped) crop origin into the cropped frame. This holds for
  # both gravity crops and coordinate crops (`crop=WxH@XxY`) — live TwicPics carries
  # the focus through a region crop (translated + clamped, the same as any other
  # geometry op), it does NOT reset it to the crop-result centre.
  defp carry_focus_through_crop(%State{} = state, %__MODULE__{}, left, top),
    do: Focus.translate(state, -left, -top)

  defp smart_crop(%__MODULE__{} = params, %State{} = state, interesting) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         crop_width = resolve_dimension(crop.width, image_width, clamp?: true),
         crop_height = resolve_dimension(crop.height, image_height, clamp?: true),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, {cropped, _attention}} <-
           Operation.smartcrop(state.image, crop_width, crop_height, interesting: interesting) do
      {:ok, set_image(state, cropped)}
    else
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp face_assist_crop(%__MODULE__{} = params, %State{} = state, module, dopts) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, ["face"], %{}, state.telemetry_opts),
         {:ok, {:fp, fx, fy}} <-
           Focal.weighted_centroid(regions, image_width(state), image_height(state), %{}),
         {:ok, {ax, ay}} <- attention_point(params, state) do
      blended = {blend_axis(ax, fx), blend_axis(ay, fy)}
      emit_blend(state.telemetry_opts, {ax, ay}, {fx, fy}, blended)
      {bx, by} = blended
      execute(%{params | gravity: {:fp, bx, by}}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end

  defp blend_axis(attention, face),
    do: clamp_unit((1 - @face_assist_weight) * attention + @face_assist_weight * face)

  # Records how face detection skewed the attention point for `{:smart,
  # :face_assist}`: the pure saliency point, the face centroid, the blended
  # result actually used, and the blend weight. A one-shot (not a span) — it is a
  # decision, not measured work. Coordinates are normalized 0..1, product-neutral,
  # and derived from the public request, so they are safe to emit.
  defp emit_blend(telemetry_opts, attention, face, blended) do
    Telemetry.execute(telemetry_opts, [:transform, :detect, :blend], %{}, %{
      attention: attention,
      face: face,
      blended: blended,
      weight: @face_assist_weight
    })
  end

  defp attention_point(%__MODULE__{} = params, %State{} = state) do
    image_width = image_width(state)
    image_height = image_height(state)

    with {:ok, crop} <- crop_dimensions(params, image_width, image_height),
         crop_width = resolve_dimension(crop.width, image_width, clamp?: true),
         crop_height = resolve_dimension(crop.height, image_height, clamp?: true),
         {crop_width, crop_height} =
           correct_aspect_ratio(
             crop_width,
             crop_height,
             params.aspect_ratio,
             params.enlarge,
             image_width,
             image_height
           ),
         {:ok, {_cropped, attention}} <-
           Operation.smartcrop(state.image, crop_width, crop_height,
             interesting: :VIPS_INTERESTING_ATTENTION
           ) do
      ax = Map.fetch!(attention, :"attention-x")
      ay = Map.fetch!(attention, :"attention-y")
      {:ok, {clamp_unit(ax / image_width), clamp_unit(ay / image_height)}}
    end
  end

  defp detect_crop(%__MODULE__{} = params, %State{} = state, spec, weights) do
    {module, dopts} = normalize_detector(state.detector)

    if is_nil(module) do
      emit_detect_skipped(spec, state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      detect_crop_with_module(params, state, module, dopts, spec, weights)
    end
  end

  defp detect_crop_with_module(
         %__MODULE__{} = params,
         %State{} = state,
         module,
         dopts,
         spec,
         weights
       ) do
    with {:ok, [_ | _] = regions} <-
           run_detect(module, dopts, state.image, spec, weights, state.telemetry_opts),
         {:ok, focal} <-
           Focal.weighted_centroid(regions, image_width(state), image_height(state), weights) do
      execute(%{params | gravity: focal}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end

  defp normalize_detector(nil), do: {nil, []}
  defp normalize_detector(module) when is_atom(module), do: {module, []}

  defp normalize_detector({module, opts}) when is_atom(module) and is_list(opts),
    do: {module, opts}

  defp run_detect(module, opts, image, classes, weights, telemetry_opts) do
    Telemetry.span(
      telemetry_opts,
      [:transform, :detect],
      %{classes: classes, weights: weights},
      fn ->
        detect_opts =
          opts |> Keyword.put(:classes, classes) |> Keyword.put(:telemetry_opts, telemetry_opts)

        result = validate_detect_result(module.detect(image, detect_opts))
        {result, %{regions: region_count(result), result: detect_reason(result)}}
      end
    )
  end

  # A face-aware request with no detector configured runs no detection, so it
  # emits a one-shot `[:transform, :detect, :skipped]` marker rather than a span
  # (a span would carry a meaningless near-zero duration). The crop falls back to
  # attention saliency.
  defp emit_detect_skipped(classes, telemetry_opts) do
    Telemetry.execute(telemetry_opts, [:transform, :detect, :skipped], %{}, %{
      classes: classes,
      result: :no_detector
    })
  end

  # The detector-level outcome recorded on the detect span's stop metadata. The
  # span wraps the detector invocation, so it only fires when a detector module
  # exists. `result` reflects what the detector returned, not the final crop
  # decision: a usable `:detected` result whose boxes all fall outside the image
  # still degrades to attention downstream. `:no_regions` is normal (no face in
  # the frame); `:unavailable` and `:error` mark a configured detector that could
  # not produce a usable detection, so the crop fell back to attention saliency.
  defp detect_reason({:ok, [_ | _]}), do: :detected
  defp detect_reason({:ok, []}), do: :no_regions
  defp detect_reason({:error, {:detector, :unavailable}}), do: :unavailable
  defp detect_reason({:error, _}), do: :error

  defp validate_detect_result({:ok, regions}) when is_list(regions) do
    if Enum.all?(regions, &valid_region?/1),
      do: {:ok, regions},
      else: {:error, {:detector, :invalid_adapter_result}}
  end

  defp validate_detect_result({:error, _} = error), do: error
  defp validate_detect_result(_other), do: {:error, {:detector, :invalid_adapter_result}}

  defp region_count({:ok, regions}), do: length(regions)
  defp region_count(_), do: 0

  defp valid_region?(%{box: {x, y, w, h}})
       when is_number(x) and is_number(y) and is_number(w) and is_number(h),
       do: true

  defp valid_region?(_), do: false

  defp clamp_unit(value), do: value |> max(0.0) |> min(1.0)

  defp default_if_nil(nil, default), do: default
  defp default_if_nil(value, _default), do: value

  defp crop_dimensions(%__MODULE__{} = params, _image_width, _image_height) do
    {:ok, %{width: params.width, height: params.height, offset_scale: params.offset_scale}}
  end

  defp gravity_crop_coordinates(
         image_width,
         image_height,
         crop_width,
         crop_height,
         gravity,
         x_offset,
         y_offset,
         center_bias
       ) do
    crop_width = max(1, min(image_width, crop_width))
    crop_height = max(1, min(image_height, crop_height))

    {left, top} =
      gravity_position(
        gravity,
        image_width,
        image_height,
        crop_width,
        crop_height,
        x_offset,
        y_offset,
        center_bias
      )

    %{
      left: clamp_position(left, image_width - crop_width),
      top: clamp_position(top, image_height - crop_height),
      width: crop_width,
      height: crop_height
    }
  end

  # Per-axis anchored position, mirroring imgproxy calc_position.go (lines 37-54).
  # The offset's SIGN depends on the anchor edge: it is ADDED from the near edge
  # (left/top/center) and SUBTRACTED from the far edge (right/bottom), so a
  # positive offset always moves the window INWARD from the named edge. imgproxy
  # rounds the offset to an even integer first (ScaleToEven/RoundToEven), then
  # combines it with an integer origin; we match that by rounding the bare offset
  # with round-half-to-even before composing.
  defp gravity_position(
         {:anchor, x_anchor, y_anchor},
         image_width,
         image_height,
         crop_width,
         crop_height,
         x_offset,
         y_offset,
         {x_bias, y_bias}
       ) do
    {
      anchor_position(x_anchor, image_width, crop_width, x_offset, x_bias),
      anchor_position(y_anchor, image_height, crop_height, y_offset, y_bias)
    }
  end

  # Focus-point gravity uses only the focus coords for placement (calc_position.go
  # lines 16-21 — GravityFocusPoint has no offset term). The separate ImagePipe
  # offset is applied as a plain inward displacement (add), consistent with the
  # near-edge convention; it is already vector-transformed for orientation upstream.
  defp gravity_position(
         {:fp, x, y},
         image_width,
         image_height,
         crop_width,
         crop_height,
         x_offset,
         y_offset,
         _center_bias
       ) do
    {
      round_ties_to_even(x * image_width - crop_width / 2 + x_offset),
      round_ties_to_even(y * image_height - crop_height / 2 + y_offset)
    }
  end

  # Near edge (West/North): pos = 0 + offset (calc_position.go:41,53).
  defp anchor_position(anchor, _bounds, _crop, offset, _bias) when anchor in [:left, :top],
    do: round_offset_to_even(offset)

  # Center: pos = ShrinkToEven(bounds - crop + 1, 2) + offset (calc_position.go:37-38).
  # ShrinkToEven(a, 2) = RoundToEven(a / 2); the offset is an even integer added
  # after. With `:far` bias the extra discarded pixel moves to the opposite side:
  # the origin becomes (bounds - crop) - ShrinkToEven(bounds - crop + 1, 2), used
  # when a later orientation flush reverses this axis (Orientation.center_discard_sides).
  defp anchor_position(:center, bounds, crop, offset, :near),
    do: center_origin(bounds, crop) + round_offset_to_even(offset)

  defp anchor_position(:center, bounds, crop, offset, :far),
    do: bounds - crop - center_origin(bounds, crop) + round_offset_to_even(offset)

  # Far edge (East/South): pos = bounds - crop - offset (calc_position.go:45,49).
  defp anchor_position(anchor, bounds, crop, offset, _bias) when anchor in [:right, :bottom],
    do: bounds - crop - round_offset_to_even(offset)

  # imgproxy converts every offset to an even integer before composing it with the
  # integer origin (ScaleToEven / RoundToEven, imath.go). The bare offset reaching
  # here is already resolved against the right bounds/scale, so round it the same
  # way to keep the composed position integer-faithful.
  defp round_offset_to_even(offset), do: round_ties_to_even(offset)

  defp clamp_position(value, max_value), do: max(0, min(max_value, value))

  defp crop_gravity({:anchor, x, y} = gravity)
       when x in [:left, :center, :right] and y in [:top, :center, :bottom],
       do: {:ok, gravity}

  defp crop_gravity({:fp, x, y} = gravity)
       when is_number(x) and is_number(y) and x >= 0.0 and x <= 1.0 and y >= 0.0 and y <= 1.0,
       do: {:ok, gravity}

  defp crop_gravity(value), do: {:error, {:invalid_crop_gravity, value}}

  defp correct_aspect_ratio(width, height, nil, _enlarge, _image_width, _image_height),
    do: {width, height}

  defp correct_aspect_ratio(
         width,
         height,
         {:ratio, numerator, denominator},
         enlarge,
         image_width,
         image_height
       ) do
    target = numerator / denominator
    current = width / height

    {corrected_width, corrected_height} =
      cond do
        current == target -> {width, height}
        enlarge and current > target -> {width, round_half_away_from_zero(width / target)}
        enlarge -> {round_half_away_from_zero(height * target), height}
        current > target -> {round_half_away_from_zero(height * target), height}
        true -> {width, round_half_away_from_zero(width / target)}
      end

    clamp_to_bounds(corrected_width, corrected_height, image_width, image_height)
  end

  defp clamp_to_bounds(width, height, image_width, image_height) do
    scale = min(1.0, min(image_width / width, image_height / height))

    width = max(1, min(image_width, round_half_away_from_zero(width * scale)))
    height = max(1, min(image_height, round_half_away_from_zero(height * scale)))

    {width, height}
  end
end
