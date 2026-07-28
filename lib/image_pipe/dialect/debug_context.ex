defmodule ImagePipe.Dialect.DebugContext do
  @moduledoc """
  Everything the runner's default neutral debug builder may draw on. Source
  facts ride `geometry.debug_facts` (collected by `ImagePipe.Decode`). Cache
  hit/miss debug (spec U13's "cache hit/miss" input) is NOT carried here:
  it rides the delivery-time `hit_debug` map exactly as today, because it
  is only known at serve time, after generation built this context.
  """

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Transform.SourceGeometry

  @enforce_keys [
    :geometry,
    :shrink,
    :negotiation,
    :resolved_output,
    :image,
    :search_meta,
    :operations,
    :timings
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          geometry: SourceGeometry.t(),
          shrink: %{w: float(), h: float()} | nil,
          negotiation: Negotiation.t(),
          resolved_output: ResolvedOutput.t(),
          image: Vix.Vips.Image.t(),
          search_meta: map() | nil,
          operations: [atom()],
          timings: %{
            decode: non_neg_integer(),
            transform: non_neg_integer(),
            encode: non_neg_integer()
          }
        }
end
