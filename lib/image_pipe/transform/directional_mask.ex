defmodule ImagePipe.Transform.DirectionalMask do
  @moduledoc false
  alias Vix.Vips.Operation

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
  # Equal start/stop produces a hard step (p < start → 0, p ≥ start → opacity),
  # avoiding division by zero.
  def build(width, height, angle, start, stop, opacity \\ 1.0) do
    with {:ok, projection} <- normalized_projection(width, height, angle) do
      ramp_mask(projection, start, stop, opacity)
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

    # Use clamp's [0, 1] defaults: Vix rejects an explicit zero minimum.
    with {:ok, ramp} <- Operation.linear(projection, [scale], [-start * scale]),
         {:ok, clamped} <- Operation.clamp(ramp) do
      Operation.linear(clamped, [opacity], [0.0])
    end
  end
end
