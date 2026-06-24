defmodule ImagePipe.Output.Metric.Ssimulacra2 do
  @moduledoc """
  Thin adapter over the `ssimulacra2` package — the only module that references
  `Ssimulacra2.*`. `reference/1` precomputes the comparison reference once (from
  the finalized pre-encode image); the loop calls `score/2` per decoded candidate.
  Scores are SSIMULACRA2-native (0–100, 100 = identical), so `direction` is
  `:higher_better`.
  """
  @behaviour ImagePipe.Output.Metric

  @type ref :: Ssimulacra2.Reference.t()

  @impl true
  def direction, do: :higher_better

  @impl true
  def target_range, do: {0, 100}

  @impl true
  @spec reference(Vix.Vips.Image.t()) :: {:ok, ref()} | {:error, term()}
  def reference(%Vix.Vips.Image{} = image), do: Ssimulacra2.Vix.reference(image)

  @impl true
  @spec score(ref(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def score(reference, %Vix.Vips.Image{} = candidate),
    do: Ssimulacra2.Vix.compare(reference, candidate)
end
