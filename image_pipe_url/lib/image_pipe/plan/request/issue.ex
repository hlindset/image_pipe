defmodule ImagePipe.Plan.Request.Issue do
  @moduledoc """
  A semantic request error, located by typed option names.

  Group indexes are zero-based. Locations are `{:group, index, key}` or
  `{:request, key}`. `detail` describes the failed constraint without carrying
  option values or source contents. URL adapters attach their own byte spans.
  """

  @enforce_keys [:reason, :locations, :detail]
  defstruct @enforce_keys

  @type location :: {:group, non_neg_integer(), atom()} | {:request, atom()}
  @type t :: %__MODULE__{reason: atom(), locations: [location()], detail: term()}
end
