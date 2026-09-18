defmodule ImagePipe.Transform.Executor.Geometry do
  @moduledoc false

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Orientation
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.State

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
