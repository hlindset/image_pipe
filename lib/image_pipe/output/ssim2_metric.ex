defmodule ImagePipe.Output.Ssim2Metric do
  @moduledoc """
  Thin adapter over the `ssimulacra2` package — the only module that references
  `Ssimulacra2.*`. `reference/1` precomputes the comparison reference once (from
  the finalized pre-encode image); the loop calls `score/2` per decoded
  candidate. Scores are SSIMULACRA2-native (0–100, 100 = identical).
  """

  @type ref :: Ssimulacra2.Reference.t()

  @spec reference(Vix.Vips.Image.t()) :: {:ok, ref()} | {:error, term()}
  def reference(%Vix.Vips.Image{} = image), do: Ssimulacra2.Vix.reference(image)

  @spec score(ref(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def score(reference, %Vix.Vips.Image{} = candidate),
    do: Ssimulacra2.Vix.compare(reference, candidate)
end
