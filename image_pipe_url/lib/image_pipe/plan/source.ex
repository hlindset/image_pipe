defmodule ImagePipe.Plan.Source do
  @moduledoc """
  Product-neutral source identifiers produced by parsers.
  """

  alias ImagePipe.Plan.Source

  @type t :: Source.Path.t() | Source.URL.t() | Source.Object.t()

  @doc """
  Removes the optional leading `/` from an ordinary root-relative source string.

  The slash is kept when removing it would change the source kind: a `//`
  prefix, or a remainder that starts with a `scheme://` prefix.
  """
  @spec normalize(String.t()) :: String.t()
  def normalize("//" <> _ = source), do: source

  def normalize("/" <> rest = source) do
    case scheme_prefix?(rest) do
      true -> source
      false -> rest
    end
  end

  def normalize(source), do: source

  # `[a-zA-Z][a-zA-Z0-9+.-]*://` at the start, scanned because OTP 28 and
  # later rebuild a regex at every use.
  defp scheme_prefix?(<<first, rest::binary>>) when first in ?a..?z or first in ?A..?Z,
    do: scheme_rest?(rest)

  defp scheme_prefix?(_source), do: false

  defp scheme_rest?("://" <> _rest), do: true

  defp scheme_rest?(<<char, rest::binary>>)
       when char in ?a..?z or char in ?A..?Z or char in ?0..?9 or char in [?+, ?., ?-],
       do: scheme_rest?(rest)

  defp scheme_rest?(_rest), do: false
end
