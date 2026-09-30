defmodule ImagePipe.Result do
  @moduledoc """
  A fully consumed plan result. It owns no open image or source resources.

  `data` is encoded bytes for `:image`, a string for `:blurhash` or `:lqip_css`,
  and a map with string keys for `:info`. Image results also carry `format`,
  `width`, and `height`. `content_type` describes the serialized representation.
  """

  @enforce_keys [:terminal, :data, :content_type]
  defstruct @enforce_keys ++ [format: nil, width: nil, height: nil]

  @type t :: %__MODULE__{
          terminal: :image | :info | :blurhash | :lqip_css,
          data: binary() | map(),
          content_type: String.t(),
          format: ImagePipe.Format.output_format() | nil,
          width: pos_integer() | nil,
          height: pos_integer() | nil
        }
end
