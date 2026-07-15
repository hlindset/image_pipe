defmodule ImagePipe.Cache.Entry.Metadata do
  @moduledoc false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Debug.Info

  @enforce_keys [:content_type, :headers, :created_at, :output_format]
  defstruct [
    :content_type,
    :headers,
    :created_at,
    :output_format,
    representation: nil,
    cost_us: 0,
    debug: nil
  ]

  # See `ImagePipe.Cache.Entry.representation/0` for the tagged-union shape.
  # `output_format` stays the image-only field it always was — a
  # `{:complete_body, _}` sink never overloads it with a non-format atom, it
  # simply has no format and leaves it `nil`.
  @type t :: %__MODULE__{
          content_type: String.t(),
          headers: [Entry.header()],
          created_at: DateTime.t(),
          output_format: atom() | nil,
          representation: Entry.representation() | nil,
          cost_us: non_neg_integer(),
          debug: Info.t() | nil
        }
end
