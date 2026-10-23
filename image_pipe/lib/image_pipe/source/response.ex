defmodule ImagePipe.Source.Response do
  @moduledoc """
  Source bytes returned by an `ImagePipe.Source` adapter.

  Exactly one of `stream` or `path` must be present. Streams are consumed
  lazily and must release their resources when enumeration halts. Adapters
  opening resources before enumeration also supply an idempotent `close`
  function. ImagePipe calls it once it is done with the response, even when
  no body is consumed.
  """

  defstruct stream: nil, path: nil, origin: nil, close: nil

  @type t :: %__MODULE__{
          stream: Enumerable.t() | nil,
          path: Path.t() | nil,
          origin: ImagePipe.Source.Origin.t() | nil,
          close: (-> :ok) | nil
        }

  @doc "Releases the response's resources by calling its `close` function."
  def close(%__MODULE__{close: nil}), do: :ok
  def close(%__MODULE__{close: close}), do: close.()
end
