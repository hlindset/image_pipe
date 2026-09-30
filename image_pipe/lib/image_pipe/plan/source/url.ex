defmodule ImagePipe.Plan.Source.URL do
  @moduledoc """
  Absolute HTTP and HTTPS source.
  """

  @enforce_keys [:scheme, :host, :path]
  defstruct [:scheme, :host, :port, :path, :query]

  @type t :: %__MODULE__{
          scheme: :http | :https,
          host: String.t(),
          port: :inet.port_number() | nil,
          path: [String.t()],
          query: String.t() | nil
        }
end
