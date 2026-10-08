defmodule ImagePipe.Plan.Angle do
  # Normalizes degrees so equal directions share one term.
  @moduledoc false

  @doc "Normalizes degrees into `[0.0, 360.0)`."
  @spec normalize(number()) :: float()
  def normalize(degrees) when is_integer(degrees), do: Integer.mod(degrees, 360) * 1.0

  # A tiny negative remainder plus a full turn rounds to 360.0, and -0.0 is a
  # distinct term from 0.0. Both mean 0.0.
  def normalize(degrees) do
    angle = :math.fmod(degrees, 360.0)
    angle = if angle < 0.0, do: angle + 360.0, else: angle
    if angle == 0.0 or angle == 360.0, do: 0.0, else: angle
  end

  @doc "Normalizes a rotation like `normalize/1`, keeping whole degrees as integers."
  @spec rotation(number()) :: non_neg_integer() | float()
  def rotation(degrees) do
    angle = normalize(degrees)
    if angle == trunc(angle), do: trunc(angle), else: angle
  end
end
