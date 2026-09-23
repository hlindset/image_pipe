defmodule ImagePipe.Transform.Operation.Crop do
  @moduledoc """
  Selects a bounded rectangle from the current image.

  The executor resolves geometry and gravity inheritance before
  constructing coordinate, gravity, or post-resize result crops.

  ## Fields

  Required fields:

  - `width`: crop width as `{:pixels, value}`.
  - `height`: crop height as `{:pixels, value}`.
  - `crop_from`: crop source, either `:gravity` or `%{left: left, top: top}`
    with `{:pixels, value}` positions clamped to the image bounds.

  Optional fields:

  - `gravity`: `nil`, an anchor tuple
    `{:anchor, :left | :center | :right, :top | :center | :bottom}`, or a
    focal point tuple `{:fp, x, y}` where `x` and `y` are normalized `0.0..1.0`
    coordinates.
  - `x_offset`: horizontal offset as a number, `{:pixels, value}`,
    or `{:scale, value}`. Defaults to `0.0`.
  - `y_offset`: vertical offset using the same units as `x_offset`. Defaults
    to `0.0`.
  - `center_bias`: `{x_side, y_side}` tie-break for a centered crop with an odd
    extent difference, each `:near` (keep the extra pixel toward the left/top
    origin, matching imgproxy `ShrinkToEven`) or `:far` (toward the right/bottom).
    Defaults to `{:near, :near}`. Only affects `:center` anchor axes; callers that
    crop in a frame that is later reversed (deferred orientation) set the
    reversed axis to `:far` so the kept pixel lands on the intended display side.

  ## Execution Semantics

  `execute/2` crops `ImagePipe.Transform.State.image` and returns a state with
  the cropped image. If coordinate mapping or image cropping fails, execution
  returns `{:error, {__MODULE__, reason}}`.

  For `crop_from: :gravity`, execution resolves crop dimensions against the
  current image, defaulting gravity to center when none is provided. Anchor
  gravity pins the crop to an edge or center. Focal-point gravity centers the
  crop around a normalized current-image point and clamps it into image bounds.

  Result crops are represented as `crop_from: :gravity` with explicit `width`
  and `height`. The executor scales pixel offsets by effective DPR; scale
  offsets are resolved relative to the current image bounds.

  Coordinate crops start at `crop_from` and clamp to image bounds. The executor
  sets `reject_out_of_bounds: true` for regions wholly outside the original
  source frame, before decode-shrink rescaling loses those coordinates. Such
  crops return `{:error, {:bad_request, :region_out_of_bounds}}` without cropping.
  The default is `false`; partially overlapping regions are never rejected.

  ## Examples

      crop = %ImagePipe.Transform.Operation.Crop{
        width: {:pixels, 300},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:fp, 0.25, 0.75},
        x_offset: {:scale, 0.1},
        y_offset: {:pixels, -12}
      }
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State, only: [set_image: 2]

  import ImagePipe.Transform.Geometry,
    only: [
      center_origin: 2,
      image_height: 1,
      image_width: 1,
      resolve_dimension: 2,
      resolve_offset: 2,
      resolve_position: 1,
      round_half_away_from_zero: 1,
      round_ties_to_even: 1
    ]

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Focal
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  @default_gravity {:anchor, :center, :center}

  # Face-favoring blend weight for `{:smart, :face_assist}` gravity. ImagePipe's
  # documented approximation of imgproxy's `smart_crop_face_detection`, whose
  # exact combination of attention saliency and detected faces is unspecified.
  @face_assist_weight 0.7

  @type pixels() :: {:pixels, integer()}
  @type offset() :: number() | {:pixels, number()} | {:scale, number()}

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
    aspect_ratio: nil,
    enlarge: false,
    reject_out_of_bounds: false,
    center_bias: {:near, :near}
  ]

  @type t :: %__MODULE__{
          width: pixels(),
          height: pixels(),
          crop_from:
            :gravity
            | %{
                left: pixels(),
                top: pixels()
              },
          gravity:
            {:anchor, :left | :center | :right, :top | :center | :bottom}
            | {:fp, float(), float()}
            | :smart
            | {:smart, :face_assist}
            | {:detect,
               {:all, %{optional(:default) => number(), optional(String.t()) => number()}}}
            | {:detect,
               {[String.t()], %{optional(:default) => number(), optional(String.t()) => number()}}}
            | nil,
          x_offset: offset(),
          y_offset: offset(),
          aspect_ratio: nil | {:ratio, pos_integer(), pos_integer()},
          enlarge: boolean(),
          reject_out_of_bounds: boolean(),
          center_bias: {:near | :far, :near | :far}
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :crop

  @doc false
  # Pure crop dimensions shared by execution and geometry planning.
  # Position does not affect the box size.
  @spec resolved_box_dims(t(), pos_integer(), pos_integer()) ::
          {pos_integer(), pos_integer()}
  def resolved_box_dims(%__MODULE__{crop_from: :gravity} = params, image_width, image_height) do
    crop_width = resolve_dimension(params.width, image_width)
    crop_height = resolve_dimension(params.height, image_height)

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
    {resolve_dimension(params.width, image_width), resolve_dimension(params.height, image_height)}
  end

  @doc false
  # Pure rectangle for anchor, focus-point, and coordinate crops. The executor
  # uses its origin to translate carried points. Smart/detect crops require pixels.
  @spec resolved_rect(t(), pos_integer(), pos_integer()) ::
          {:ok, %{left: integer(), top: integer(), width: pos_integer(), height: pos_integer()}}
          | {:error, term()}
  def resolved_rect(%__MODULE__{crop_from: :gravity} = params, image_width, image_height) do
    {crop_width, crop_height} = resolved_box_dims(params, image_width, image_height)

    with {:ok, gravity} <- crop_gravity(default_if_nil(params.gravity, @default_gravity)) do
      x_offset = resolve_offset(params.x_offset, image_width)
      y_offset = resolve_offset(params.y_offset, image_height)

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
    left_px = resolve_position(left_coord)
    top_px = resolve_position(top_coord)

    crop_width = resolve_dimension(params.width, image_width)
    crop_height = resolve_dimension(params.height, image_height)

    center_x = round(left_px + crop_width / 2)
    center_y = round(top_px + crop_height / 2)

    left = max(0, min(image_width - crop_width, round(center_x - crop_width / 2)))
    top = max(0, min(image_height - crop_height, round(center_y - crop_height / 2)))

    {:ok, %{left: left, top: top, width: crop_width, height: crop_height}}
  end

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{gravity: :smart}), do: true
  def requires_materialization?(%__MODULE__{gravity: {:smart, _}}), do: true
  def requires_materialization?(%__MODULE__{gravity: {:detect, _}}), do: true
  def requires_materialization?(%__MODULE__{}), do: false

  @impl ImagePipe.Transform
  def execute(%__MODULE__{gravity: :smart} = params, %State{} = state) do
    smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
  end

  def execute(%__MODULE__{gravity: {:detect, {spec, weights}}} = params, %State{} = state) do
    detect_crop(params, state, spec, weights)
  end

  def execute(%__MODULE__{gravity: {:smart, :face_assist}} = params, %State{} = state) do
    if is_nil(state.detector) do
      emit_detect_skipped(["face"], state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      face_assist_crop(params, state)
    end
  end

  # A coordinate region the executor found wholly outside the source. Returning the
  # {:bad_request, _} reason unwrapped preserves the 400 response.
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

  defp crop_image(%__MODULE__{}, %State{} = state, {left, top, crop_width, crop_height}) do
    case Image.crop(state.image, left, top, crop_width, crop_height) do
      {:ok, cropped_image} -> {:ok, set_image(state, cropped_image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp smart_crop(%__MODULE__{} = params, %State{} = state, interesting) do
    image_width = image_width(state)
    image_height = image_height(state)

    {crop_width, crop_height} = resolved_box_dims(params, image_width, image_height)

    case Operation.smartcrop(state.image, crop_width, crop_height, interesting: interesting) do
      {:ok, {cropped, _attention}} -> {:ok, set_image(state, cropped)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp face_assist_crop(%__MODULE__{} = params, %State{} = state) do
    with {:ok, [_ | _] = regions} <-
           run_detect(state, ["face"], %{}),
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

  # Records the saliency point, face centroid, blended point, and blend weight.
  # These normalized coordinates are non-sensitive metadata. Emit a one-shot
  # event because this records a decision rather than measured work.
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

    {crop_width, crop_height} = resolved_box_dims(params, image_width, image_height)

    with {:ok, {_cropped, attention}} <-
           Operation.smartcrop(state.image, crop_width, crop_height,
             interesting: :VIPS_INTERESTING_ATTENTION
           ) do
      ax = Map.fetch!(attention, :"attention-x")
      ay = Map.fetch!(attention, :"attention-y")
      {:ok, {clamp_unit(ax / image_width), clamp_unit(ay / image_height)}}
    end
  end

  defp detect_crop(%__MODULE__{} = params, %State{} = state, spec, weights) do
    if is_nil(state.detector) do
      emit_detect_skipped(spec, state.telemetry_opts)
      smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    else
      detect_crop_with_module(params, state, spec, weights)
    end
  end

  defp detect_crop_with_module(
         %__MODULE__{} = params,
         %State{} = state,
         spec,
         weights
       ) do
    with {:ok, [_ | _] = regions} <-
           run_detect(state, spec, weights),
         {:ok, focal} <-
           Focal.weighted_centroid(regions, image_width(state), image_height(state), weights) do
      execute(%{params | gravity: focal}, state)
    else
      _ -> smart_crop(params, state, :VIPS_INTERESTING_ATTENTION)
    end
  end

  defp run_detect(state, classes, weights) do
    Telemetry.span(
      state.telemetry_opts,
      [:transform, :detect],
      %{classes: classes, weights: weights},
      fn ->
        detect_opts = [classes: classes, telemetry_opts: state.telemetry_opts]

        result = validate_detect_result(state.detector.detect(state.image, detect_opts))
        {result, %{regions: region_count(result), result: detect_reason(result)}}
      end
    )
  end

  # No detector means attention fallback. Emit a skipped marker rather than
  # timing work that did not run.
  defp emit_detect_skipped(classes, telemetry_opts) do
    Telemetry.execute(telemetry_opts, [:transform, :detect, :skipped], %{}, %{
      classes: classes,
      result: :no_detector
    })
  end

  # Span outcomes describe detection, not final crop placement: :detected boxes
  # outside the image can still lead to attention fallback. :no_regions is normal;
  # :unavailable and :error indicate a configured detector could not provide results.
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

  # Positive offsets add for left/top/center and subtract for right/bottom.
  # Round the offset ties-to-even before adding it to the integer origin, matching
  # imgproxy's calc_position.go.
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

  # Focus-point placement adds the separate displacement, which the executor has
  # already transformed for pending orientation.
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

  # Add the rounded offset to the shared center origin. :far reflects that origin
  # across the gap to preserve rounding when the orientation flush reverses an axis.
  defp anchor_position(:center, bounds, crop, offset, :near),
    do: center_origin(bounds, crop) + round_offset_to_even(offset)

  defp anchor_position(:center, bounds, crop, offset, :far),
    do: bounds - crop - center_origin(bounds, crop) + round_offset_to_even(offset)

  # Far edge (East/South): pos = bounds - crop - offset (calc_position.go:45,49).
  defp anchor_position(anchor, bounds, crop, offset, _bias) when anchor in [:right, :bottom],
    do: bounds - crop - round_offset_to_even(offset)

  # Offsets already have resolved bounds/scale; round ties-to-even before placement.
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
