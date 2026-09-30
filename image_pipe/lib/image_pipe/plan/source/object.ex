defmodule ImagePipe.Plan.Source.Object do
  @moduledoc """
  Product-neutral bucket or container object source.
  """

  @enforce_keys [:adapter, :scope, :key]
  defstruct [:adapter, :scope, :key, :revision]

  @type t :: %__MODULE__{
          adapter: atom(),
          scope: String.t(),
          key: String.t(),
          revision: String.t() | nil
        }
end
