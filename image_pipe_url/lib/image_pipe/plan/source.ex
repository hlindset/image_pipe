defmodule ImagePipe.Plan.Source do
  @moduledoc """
  Product-neutral source identifiers produced by parsers.
  """

  alias ImagePipe.Plan.Source

  @type t :: Source.Path.t() | Source.URL.t() | Source.Object.t()

  @scheme_prefix ~r/^([a-zA-Z][a-zA-Z0-9+.\-]*):\/\//

  @doc """
  Removes the optional leading `/` from an ordinary root-relative source string.

  The slash is kept when removing it would change the source kind: a `//`
  prefix, or a remainder that starts with a `scheme://` prefix.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize("//" <> _ = source), do: source

  def normalize("/" <> rest = source) do
    case Regex.match?(@scheme_prefix, rest) do
      true -> source
      false -> rest
    end
  end

  def normalize(source), do: source
end
