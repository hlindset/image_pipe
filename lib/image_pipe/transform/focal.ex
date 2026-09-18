defmodule ImagePipe.Transform.Focal do
  @moduledoc false
  # Pure centroid for object gravity. Each region's box center is weighted by
  # its class weight times √area.

  @type region :: %{
          optional(:label) => String.t() | nil,
          optional(any()) => any(),
          box: {number(), number(), number(), number()}
        }
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}

  @spec weighted_centroid([region()], number(), number(), weights()) ::
          {:ok, {:fp, float(), float()}} | :none
  def weighted_centroid(regions, image_width, image_height, weights) do
    in_image =
      Enum.filter(regions, fn %{box: {x, y, w, h}} ->
        w > 0 and h > 0 and x >= 0 and y >= 0 and x + w <= image_width and y + h <= image_height
      end)

    case in_image do
      [] ->
        :none

      boxes ->
        total = Enum.reduce(boxes, 0.0, fn region, acc -> acc + region_pull(region, weights) end)

        {sx, sy} =
          Enum.reduce(boxes, {0.0, 0.0}, fn %{box: {x, y, w, h}} = region, {ax, ay} ->
            pull = region_pull(region, weights)
            {ax + pull * (x + w / 2), ay + pull * (y + h / 2)}
          end)

        {:ok, {:fp, clamp_unit(sx / total / image_width), clamp_unit(sy / total / image_height)}}
    end
  end

  defp region_pull(%{box: {_x, _y, w, h}} = region, weights) do
    class_weight(Map.get(region, :label), weights) * area_term(w, h)
  end

  # √area preserves size influence while letting class weights affect smaller boxes.
  defp area_term(w, h), do: :math.sqrt(w * h)

  defp class_weight(label, weights) do
    Map.get(weights, label, Map.get(weights, :default, 1.0))
  end

  defp clamp_unit(value) when value < 0.0, do: 0.0
  defp clamp_unit(value) when value > 1.0, do: 1.0
  defp clamp_unit(value), do: value
end
