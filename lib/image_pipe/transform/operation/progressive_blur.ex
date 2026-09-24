defmodule ImagePipe.Transform.Operation.ProgressiveBlur do
  @moduledoc """
  Spatially varying Gaussian blur, interpolated between eight sigma intervals.

  Each pixel blends its two adjacent blur levels. Filtering and interpolation
  both use premultiplied alpha. The shared input is materialized because the
  differently sized convolution windows revisit its pixels.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.DirectionalMask
  alias ImagePipe.Transform.Operation.AlphaPremultiply
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @levels 8
  @enforce_keys [:sigma, :angle, :start, :stop]
  defstruct [:sigma, :angle, :start, :stop]

  @type t :: %__MODULE__{sigma: float(), angle: float(), start: float(), stop: float()}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :progressive_blur

  @impl ImagePipe.Transform
  def requires_materialization?(%__MODULE__{}), do: true

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    case apply_blur(state.image, op) do
      {:ok, image} -> {:ok, State.set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  defp apply_blur(image, op) do
    with {:ok, ramp} <-
           DirectionalMask.build(
             Image.width(image),
             Image.height(image),
             op.angle,
             op.start,
             op.stop
           ),
         {:ok, result} <-
           AlphaPremultiply.with_alpha_premultiplied(image, &filter(&1, ramp, op.sigma)),
         {:ok, active} <- Operation.relational_const(ramp, :VIPS_OPERATION_RELATIONAL_MORE, [0.0]) do
      Operation.ifthenelse(active, result, image)
    end
  end

  defp filter(image, ramp, sigma) do
    with {:ok, result} <- blend_levels(image, ramp, sigma) do
      Operation.cast(result, VipsImage.format(image))
    end
  end

  defp blend_levels(image, ramp, sigma) do
    with {:ok, weight} <- level_weight(ramp, 0),
         {:ok, initial} <- Operation.multiply(image, weight) do
      Enum.reduce_while(1..@levels, {:ok, initial}, &add_level(&2, image, ramp, sigma, &1))
    end
  end

  defp add_level({:ok, acc}, image, ramp, sigma, level) do
    with {:ok, blurred} <- Image.blur(image, sigma: sigma * level / @levels),
         {:ok, weight} <- level_weight(ramp, level),
         {:ok, term} <- Operation.multiply(blurred, weight),
         {:ok, sum} <- Operation.add(acc, term) do
      {:cont, {:ok, sum}}
    else
      error -> {:halt, error}
    end
  end

  # Triangular weights partition the ramp: only adjacent levels contribute.
  defp level_weight(ramp, level) do
    with {:ok, offset} <- Operation.linear(ramp, [@levels * 1.0], [-level * 1.0]),
         {:ok, distance} <- Operation.abs(offset),
         {:ok, weight} <- Operation.linear(distance, [-1.0], [1.0]) do
      Operation.clamp(weight)
    end
  end
end
