defmodule ImagePipe.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Debug.Info

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct [:content_type, :headers, :created_at, :output_format, cost_us: 0, debug: nil]

  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom(),
          cost_us: non_neg_integer(),
          debug: Info.t() | nil
        }
end
