defmodule ImagePipe.Output.Metric.Butteraugli do
  @moduledoc """
  Adapter over the `butteraugli` NIF — the only module that references
  `Butteraugli.*`. `reference/1` builds a reusable reference from the finalized
  pre-encode image; the loop calls `score/2` per decoded candidate. The targeted
  value is `Result.score` — the headline max butteraugli distance (lower = better;
  ~1.0 visually lossless), the same quantity libvips' JXL `distance` knob targets.
  `target_range` is libvips `jxlsave`'s own `distance` bound (min 0 / max 25).
  """
  @behaviour ImagePipe.Output.Metric

  alias ImagePipe.Plan.Output.QualitySearch.Metric

  @impl true
  def direction, do: Metric.direction(:butteraugli)

  @impl true
  def target_range, do: Metric.target_range(:butteraugli)

  @impl true
  def leg_name, do: :butteraugli

  @impl true
  @spec reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  def reference(%Vix.Vips.Image{} = image), do: Butteraugli.Vix.reference(image)

  @impl true
  @spec score(term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}
  def score(reference, %Vix.Vips.Image{} = candidate) do
    case Butteraugli.Vix.compare(reference, candidate) do
      {:ok, %{score: score}} -> {:ok, score}
      {:error, _reason} = err -> err
    end
  end
end
