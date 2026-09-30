defmodule ImagePipe.Error do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: []

  @spec tag(term()) :: atom()
  def tag({tag, _value}) when is_atom(tag), do: tag
  def tag({tag, _value, _extra}) when is_atom(tag), do: tag
  def tag(tag) when is_atom(tag), do: tag
  def tag(_reason), do: :error
end
