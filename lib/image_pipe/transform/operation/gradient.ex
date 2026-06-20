defmodule ImagePipe.Transform.Operation.Gradient do
  @moduledoc """
  Executable transparency→color gradient overlay.

  out = src·(1−m) + color·m, where m = opacity · clamp01((p − start)/(stop − start))
  and p is the normalized projection of each pixel onto the gradient direction.

  `angle` is canonical clockwise degrees (0=down, 90=left, 180=up, 270=right).
  """

  use ImagePipe.Transform

  import ImagePipe.Transform.State

  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @enforce_keys [:opacity, :color, :angle, :start, :stop]
  defstruct [:opacity, :color, :angle, :start, :stop]

  @type t :: %__MODULE__{
          opacity: float(),
          color: [0..255],
          angle: float(),
          start: float(),
          stop: float()
        }

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :gradient

  @impl ImagePipe.Transform
  def execute(%__MODULE__{} = op, %State{} = state) do
    case apply_gradient(state.image, op) do
      {:ok, image} -> {:ok, set_image(state, image)}
      {:error, error} -> {:error, {__MODULE__, error}}
    end
  end

  # Gradient always preserves the source alpha, which is exactly what
  # Image.without_alpha_band/2 does: it strips alpha, runs the fn over the RGB
  # bands, and rejoins the original alpha unchanged.
  defp apply_gradient(%VipsImage{} = image, %__MODULE__{} = op) do
    width = VipsImage.width(image)
    height = VipsImage.height(image)

    Image.without_alpha_band(image, fn rgb ->
      with {:ok, mask} <- gradient_mask(width, height, op),
           {:ok, blended} <- blend(rgb, mask, op.color) do
        Operation.cast(blended, VipsImage.format(rgb))
      end
    end)
  end

  # Build a single-band float mask m ∈ [0,1].
  #
  #   1. xyz → 2-band [x, y]; normalize each axis to [0,1] (nx, ny).
  #   2. project q = nx·dx + ny·dy onto the direction unit vector for `angle`
  #      (dx = -sin θ, dy = cos θ, clockwise, 0°=down). The projection's extremes
  #      over the image rectangle occur at corners, so q ∈ [q_min, q_max] with
  #      q_min = min(0,dx)+min(0,dy), q_max = max(0,dx)+max(0,dy). q_max − q_min =
  #      |dx|+|dy| ≥ 1 (never zero), so p = (q − q_min)/(q_max − q_min) ∈ [0,1].
  #   3. m = opacity · clamp01((p − start)/(stop − start)).
  #
  # DEGENERATE GUARD: when stop == start the ramp divisor is 0. Treat it as a hard
  # step at `start` (p < start → 0, p ≥ start → opacity), guarded BEFORE dividing.
  defp gradient_mask(width, height, %__MODULE__{} = op) do
    with {:ok, projection} <- normalized_projection(width, height, op.angle) do
      ramp_mask(projection, op.start, op.stop, op.opacity)
    end
  end

  defp normalized_projection(width, height, angle) do
    radians = angle * :math.pi() / 180.0
    dx = -:math.sin(radians)
    dy = :math.cos(radians)

    q_min = min(0.0, dx) + min(0.0, dy)
    q_max = max(0.0, dx) + max(0.0, dy)
    span = q_max - q_min

    sx = axis_scale(width)
    sy = axis_scale(height)

    with {:ok, coords} <- Operation.xyz(width, height),
         # [nx·dx, ny·dy]
         {:ok, projected} <- Operation.linear(coords, [dx * sx, dy * sy], [0.0, 0.0]),
         {:ok, qx} <- Operation.extract_band(projected, 0, n: 1),
         {:ok, qy} <- Operation.extract_band(projected, 1, n: 1),
         {:ok, q} <- Operation.add(qx, qy) do
      # p = (q − q_min) / span
      Operation.linear(q, [1.0 / span], [-q_min / span])
    end
  end

  # nx = x/(w−1); a 1px axis has no extent, so its coordinate is always 0.
  defp axis_scale(1), do: 0.0
  defp axis_scale(size), do: 1.0 / (size - 1)

  defp ramp_mask(projection, start, stop, opacity) when start == stop do
    with {:ok, step} <-
           Operation.relational_const(projection, :VIPS_OPERATION_RELATIONAL_MOREEQ, [start]) do
      # relational_const yields 255 / 0; rescale to opacity / 0.
      Operation.linear(step, [opacity / 255.0], [0.0])
    end
  end

  defp ramp_mask(projection, start, stop, opacity) do
    scale = 1.0 / (stop - start)

    # clamp/2 defaults to min: 0.0, max: 1.0 — exactly clamp01. Passing min: 0.0
    # explicitly is rejected by Vix's positive-double validation, so rely on the
    # defaults.
    with {:ok, ramp} <- Operation.linear(projection, [scale], [-start * scale]),
         {:ok, clamped} <- Operation.clamp(ramp) do
      Operation.linear(clamped, [opacity], [0.0])
    end
  end

  defp blend(rgb, mask, [cr, cg, cb]) do
    with {:ok, mask3} <- Operation.bandjoin([mask, mask, mask]),
         {:ok, inv3} <- Operation.linear(mask3, [-1.0, -1.0, -1.0], [1.0, 1.0, 1.0]),
         {:ok, src_term} <- Operation.multiply(rgb, inv3),
         {:ok, color_img} <- color_constant(rgb, [cr, cg, cb]),
         {:ok, col_term} <- Operation.multiply(color_img, mask3) do
      Operation.add(src_term, col_term)
    end
  end

  defp color_constant(ref, channels) do
    case Operation.black(VipsImage.width(ref), VipsImage.height(ref), bands: length(channels)) do
      {:ok, base} -> Operation.linear(base, [1.0], Enum.map(channels, &(&1 * 1.0)))
      error -> error
    end
  end
end
