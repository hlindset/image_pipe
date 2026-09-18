defmodule ImagePipe.Transform.Executor.Geometry do
  @moduledoc false

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

  @spec resize_target(
          ImagePipe.Plan.Request.Group.resize(),
          float(),
          {pos_integer(), pos_integer()}
        ) ::
          {atom(), %{width: pos_integer(), height: pos_integer(), dpr: float()}}
  def resize_target(resize, dpr, {width, height} = source) do
    mode = resize_mode(resize, source)
    base = resize_base(resize, mode, source)
    scale = max(minimum_scale(resize.min_w, base.width), minimum_scale(resize.min_h, base.height))
    base = %{width: base.width * scale, height: base.height * scale}

    dpr =
      case resize.enlarge and mode != :cover_down do
        true -> dpr
        false -> min(dpr, min(width / base.width, height / base.height))
      end

    {mode,
     %{
       width: positive_round(base.width * dpr),
       height: positive_round(base.height * dpr),
       dpr: dpr
     }}
  end

  @spec resize_dimensions(atom(), map(), {pos_integer(), pos_integer()}) ::
          {pos_integer(), pos_integer()}
  def resize_dimensions(mode, target, {width, height})
      when mode in [:cover, :cover_down, :auto_cover] do
    source_ratio = width / height

    case source_ratio > target.width / target.height do
      true -> {positive_round(target.height * source_ratio), target.height}
      false -> {target.width, positive_round(target.width / source_ratio)}
    end
  end

  def resize_dimensions(_mode, target, _source), do: {target.width, target.height}

  defp resize_mode(%{fit: :auto, w: w, h: h, zoom: {zoom_x, zoom_y}}, {sw, sh})
       when is_integer(w) and is_integer(h) do
    case sw >= sh == w * zoom_x >= h * zoom_y do
      true -> :auto_cover
      false -> :auto_contain
    end
  end

  defp resize_mode(%{fit: :auto}, _source), do: :auto_contain
  defp resize_mode(%{fit: fit}, _source), do: fit

  defp resize_base(%{w: :auto, h: :auto, zoom: {zoom_x, zoom_y}}, mode, {width, height} = source) do
    %{width: width * zoom_x, height: height * zoom_y}
    |> fit_box(mode, source)
  end

  defp resize_base(%{w: w, h: h, zoom: {zoom_x, zoom_y}}, mode, source) do
    {zoom_axis(w, zoom_x), zoom_axis(h, zoom_y)}
    |> resize_box(mode, source)
    |> fit_box(mode, source)
  end

  defp zoom_axis(:auto, _zoom), do: :auto
  defp zoom_axis(value, zoom), do: value * zoom

  defp resize_box({:auto, height}, :stretch, {width, _height}),
    do: %{width: width, height: height}

  defp resize_box({width, :auto}, :stretch, {_width, height}), do: %{width: width, height: height}

  defp resize_box({:auto, height}, _mode, {sw, sh}),
    do: %{width: height * sw / sh, height: height}

  defp resize_box({width, :auto}, _mode, {sw, sh}), do: %{width: width, height: width * sh / sw}
  defp resize_box({width, height}, _mode, _source), do: %{width: width, height: height}

  defp fit_box(%{width: width, height: height}, mode, {sw, sh})
       when mode in [:contain, :auto_contain] do
    ratio = sw / sh

    case ratio > width / height do
      true -> %{width: width, height: width / ratio}
      false -> %{width: height * ratio, height: height}
    end
  end

  defp fit_box(box, _mode, _source), do: box
  defp minimum_scale(nil, _base), do: 1.0
  defp minimum_scale(minimum, base), do: max(1.0, minimum / base)
  defp positive_round(value), do: max(1, round(value))

  @spec live_dims(State.t()) :: {pos_integer(), pos_integer()}
  def live_dims(%State{image: image}), do: {Image.width(image), Image.height(image)}

  @spec effective_dims(State.t()) :: {pos_integer(), pos_integer()}
  def effective_dims(%State{} = state), do: State.effective_source_dims(state)

  @spec display_effective_dims(State.t()) :: {pos_integer(), pos_integer()}
  def display_effective_dims(%State{} = state) do
    state |> effective_dims() |> PendingOrientation.display_dims(state.pending_orientation)
  end

  @spec display_live_dims(State.t()) :: {pos_integer(), pos_integer()}
  def display_live_dims(%State{} = state) do
    state |> live_dims() |> PendingOrientation.display_dims(state.pending_orientation)
  end

  @spec pending_class(State.t()) :: :none | :identity | :pending
  def pending_class(%State{pending_orientation: nil}), do: :none

  def pending_class(%State{pending_orientation: %PendingOrientation{} = pending}) do
    if PendingOrientation.identity?(pending), do: :identity, else: :pending
  end

  @spec clear_source_frame(State.t()) :: State.t()
  def clear_source_frame(%State{} = state),
    do: %State{state | source_dimensions: nil, decode_shrink: nil}

  @spec orient_decode_shrink(nil | %{w: float(), h: float()}, PendingOrientation.t()) ::
          nil | %{w: float(), h: float()}
  def orient_decode_shrink(nil, %PendingOrientation{}), do: nil

  def orient_decode_shrink(%{w: w, h: h} = shrink, %PendingOrientation{} = pending) do
    if PendingOrientation.quarter_turn?(pending), do: %{shrink | w: h, h: w}, else: shrink
  end

  @spec rescale_crop(Crop.t(), nil | %{w: float(), h: float()}) :: Crop.t()
  def rescale_crop(%Crop{} = crop, nil), do: crop

  def rescale_crop(%Crop{} = crop, %{w: w_shrink, h: h_shrink}) do
    %Crop{
      crop
      | width: shrink_dimension(crop.width, w_shrink),
        height: shrink_dimension(crop.height, h_shrink),
        crop_from: shrink_crop_from(crop.crop_from, w_shrink, h_shrink),
        x_offset: shrink_offset(crop.x_offset, crop.gravity, w_shrink),
        y_offset: shrink_offset(crop.y_offset, crop.gravity, h_shrink)
    }
  end

  @spec compensate_crop(Crop.t(), PendingOrientation.t()) :: Crop.t()
  def compensate_crop(%Crop{crop_from: :gravity, gravity: gravity} = crop, pending) do
    if materializing_gravity?(gravity) do
      crop
    else
      crop
      |> remap_offsets(pending)
      |> then(fn %Crop{} = crop ->
        %Crop{crop | center_bias: Orientation.center_discard_sides(pending)}
      end)
      |> swap_crop_box(pending)
    end
  end

  def compensate_crop(%Crop{} = crop, %PendingOrientation{}), do: crop

  @spec round_half_to_even(number()) :: integer()
  def round_half_to_even(value) do
    floor = Float.floor(value)
    fraction = value - floor

    cond do
      fraction < 0.5 -> trunc(floor)
      fraction > 0.5 -> trunc(floor) + 1
      rem(trunc(floor), 2) == 0 -> trunc(floor)
      true -> trunc(floor) + 1
    end
  end

  defp shrink_dimension({:pixels, value}, shrink),
    do: {:pixels, max(1, round(value / shrink))}

  defp shrink_dimension(other, _shrink), do: other

  defp shrink_crop_from(%{left: left, top: top}, w_shrink, h_shrink) do
    %{
      left: shrink_coordinate(left, w_shrink),
      top: shrink_coordinate(top, h_shrink)
    }
  end

  defp shrink_crop_from(other, _w_shrink, _h_shrink), do: other

  defp shrink_coordinate({:pixels, value}, shrink),
    do: {:pixels, max(0, round(value / shrink))}

  defp shrink_coordinate(other, _shrink), do: other

  defp shrink_offset(offset, {:fp, _x, _y}, _shrink), do: offset

  defp shrink_offset({:pixels, value}, _gravity, shrink),
    do: {:pixels, round_half_to_even(value / shrink)}

  defp shrink_offset(other, _gravity, _shrink), do: other

  defp remap_offsets(%Crop{gravity: {tag, _, _} = gravity} = crop, pending)
       when tag in [:anchor, :fp] do
    {x_unit, x_value} = split_offset(crop.x_offset)
    {y_unit, y_value} = split_offset(crop.y_offset)

    {gravity, x_value, y_value} =
      Orientation.compensate_gravity_for({gravity, x_value, y_value}, pending)

    {x_unit, y_unit} =
      if PendingOrientation.quarter_turn?(pending), do: {y_unit, x_unit}, else: {x_unit, y_unit}

    %Crop{
      crop
      | gravity: gravity,
        x_offset: x_unit.(x_value),
        y_offset: y_unit.(y_value)
    }
  end

  defp remap_offsets(%Crop{} = crop, %PendingOrientation{}), do: crop

  defp swap_crop_box(%Crop{} = crop, %PendingOrientation{} = pending) do
    if PendingOrientation.quarter_turn?(pending) do
      %Crop{crop | width: crop.height, height: crop.width}
    else
      crop
    end
  end

  defp split_offset({:pixels, value}), do: {&{:pixels, &1}, value * 1.0}
  defp split_offset({:scale, value}), do: {&{:scale, &1}, value * 1.0}
  defp split_offset(value) when is_number(value), do: {& &1, value * 1.0}

  defp materializing_gravity?(:smart), do: true
  defp materializing_gravity?({:smart, _}), do: true
  defp materializing_gravity?({:detect, _}), do: true
  defp materializing_gravity?(_gravity), do: false
end
