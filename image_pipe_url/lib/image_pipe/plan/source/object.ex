defmodule ImagePipe.Plan.Source.Object do
  @moduledoc """
  Product-neutral bucket or container object source, such as `s3://bucket/key`.
  """

  @enforce_keys [:scheme, :scope, :key]
  defstruct [:scheme, :scope, :key, :revision]

  @type t :: %__MODULE__{
          scheme: String.t(),
          scope: String.t(),
          key: String.t(),
          revision: String.t() | nil
        }
end
