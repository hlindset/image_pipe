defmodule ImagePipe.Transform.Operation.StateUpdate do
  @moduledoc """
  Executable state update operation that merges non-image fields into State.

  This operation provides a neutral channel for resolvers and other runtime
  logic to commit updates to State fields (such as `:focus`) without modifying
  the image itself. The image is untouched; only the specified fields are
  merged into the state struct.

  Useful for carrying forward resolver-computed state changes alongside
  the image transformation chain.
  """

  use ImagePipe.Transform

  alias ImagePipe.Transform.State

  @enforce_keys [:fields]
  defstruct [:fields]

  @type t :: %__MODULE__{fields: %{optional(atom()) => term()}}

  @impl ImagePipe.Transform
  def name(%__MODULE__{}), do: :state_update

  @impl ImagePipe.Transform
  def execute(%__MODULE__{fields: fields}, %State{} = state) do
    {:ok, struct!(state, fields)}
  end
end
