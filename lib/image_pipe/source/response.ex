defmodule ImagePipe.Source.Response do
  @moduledoc """
  Source bytes returned by an `ImagePipe.Source` adapter.

  Exactly one of `stream` or `path` must be present. Streams are consumed
  lazily and must release their resources when enumeration halts. Adapters
  opening resources before enumeration also supply an idempotent `close`
  function. `Source.with_fetched/3` closes it even when no body is consumed.
  """

  defstruct stream: nil, path: nil, origin: nil, close: nil

  @type t :: %__MODULE__{
          stream: Enumerable.t() | nil,
          path: Path.t() | nil,
          origin: ImagePipe.Source.Origin.t() | nil,
          close: (-> :ok) | nil
        }

  @doc "Releases a response obtained directly through Source.fetch/3."
  def close(%__MODULE__{close: nil}), do: :ok
  def close(%__MODULE__{close: close}), do: close.()
end
