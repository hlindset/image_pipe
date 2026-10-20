defmodule ImagePipe.Plan.Source do
  @moduledoc """
  Normalizes source strings the same way for the URL builder and the server.
  """

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

  # Normalizes a source and checks that the server can serve it: not empty
  # after normalizing, valid UTF-8, and without a NUL byte, which no path or
  # object key can hold.
  @doc false
  @spec check(term()) :: {:ok, String.t()} | :error
  def check(source) when is_binary(source) do
    source = normalize(source)

    case source != "" and String.valid?(source) and not String.contains?(source, <<0>>) do
      true -> {:ok, source}
      false -> :error
    end
  end

  def check(_source), do: :error

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
