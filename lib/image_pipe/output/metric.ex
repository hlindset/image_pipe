defmodule ImagePipe.Output.Metric do
  @moduledoc """
  Perceptual-quality metric runtime behaviour for the autoquality external-measure
  search. One module per metric owns its measurement semantics; the search loop
  reads `direction/0` to orient its band walk and calls `reference/1` + `score/2`.
  `runtime/1` maps a resolved external-measure search struct to its runtime module.
  Native-encoder realization (e.g. JXL `distance`) is a resolve-time *strategy*
  choice, not a callback here.
  """
  alias ImagePipe.Output.ResolvedQualitySearch, as: RQS

  @callback direction() :: :higher_better | :lower_better
  @callback target_range() :: {number(), number()}
  @callback reference(Vix.Vips.Image.t()) :: {:ok, term()} | {:error, term()}
  @callback score(reference :: term(), Vix.Vips.Image.t()) :: {:ok, float()} | {:error, term()}

  @spec runtime(RQS.Ssimulacra2.t() | RQS.Butteraugli.t()) :: module()
  def runtime(%RQS.Ssimulacra2{}), do: __MODULE__.Ssimulacra2
  def runtime(%RQS.Butteraugli{}), do: __MODULE__.Butteraugli
end
