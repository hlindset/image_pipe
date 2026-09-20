defmodule ImagePipe.Source.Record do
  @moduledoc "Source byte identity and origin evidence shared by input and output entries."
  alias ImagePipe.Source.CacheState
  alias ImagePipe.Source.Origin
  @enforce_keys [:byte_identity, :origin, :received_at]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          byte_identity: {:strong, term()},
          origin: Origin.t() | nil,
          received_at: integer()
        }

  def new(source, digest, origin, now) do
    identity =
      case source.cache_semantics.byte_identity do
        :none -> {:strong, {:source_sha256, digest}}
        strong -> strong
      end

    %__MODULE__{byte_identity: identity, origin: origin, received_at: now}
  end

  def refresh(record, origin), do: %{record | origin: origin, received_at: origin.received_at}

  def state(%__MODULE__{origin: nil} = record, semantics) do
    CacheState.from_headers(
      %{},
      semantics.policy,
      semantics.stable?,
      {record.received_at, record.received_at}
    )
  end

  def state(%__MODULE__{origin: origin}, semantics),
    do: Origin.cache_state(origin, semantics.policy, semantics.stable?)

  def valid?(%__MODULE__{byte_identity: {:strong, _}, origin: origin, received_at: received}) do
    is_integer(received) and (is_nil(origin) or Origin.valid?(origin))
  end

  def valid?(_), do: false
end
