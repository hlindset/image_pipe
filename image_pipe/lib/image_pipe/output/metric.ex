defmodule ImagePipe.Output.Metric do
  # Runtime behaviour for perceptual quality metrics.
  #
  # Each metric defines its reference image, score, and whether higher or lower
  # scores are better. `runtime/1` selects the metric module for a resolved quality
  # search.
  @moduledoc false
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  @callback direction() :: :higher_better | :lower_better
  @callback reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  @callback score(reference :: term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}

  # The span segment qualifying this metric's probe cost legs
  # (`[:encode, :search, :probe, <leg_name>, :decode | :metric]`), so a backend can
  # group the decode/score legs by metric.
  @callback leg_name() :: atom()

  @spec runtime(RQS.Ssimulacra2.t() | RQS.Butteraugli.t()) :: module()
  def runtime(%RQS.Ssimulacra2{}), do: __MODULE__.Ssimulacra2
  def runtime(%RQS.Butteraugli{}), do: __MODULE__.Butteraugli
end
