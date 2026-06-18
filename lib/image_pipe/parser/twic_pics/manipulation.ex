defmodule ImagePipe.Parser.TwicPics.Manipulation do
  @moduledoc false

  @spec parse(String.t()) :: {:ok, [{String.t(), String.t()}]} | {:error, term()}
  def parse("v1/" <> rest), do: segments(rest)
  def parse("v1"), do: {:ok, []}
  def parse(other), do: {:error, {:unsupported_manipulation_version, other}}

  defp segments(rest) do
    rest
    |> split_top_level()
    |> Enum.reduce_while({:ok, []}, fn segment, {:ok, acc} ->
      case String.split(segment, "=", parts: 2) do
        [name, args] -> {:cont, {:ok, [{name, args} | acc]}}
        [name] -> {:halt, {:error, {:invalid_segment, name}}}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  # Split the chain on `/` at parenthesis depth 0 only — a `/` inside a
  # parenthesized `number` expression (`resize=(700/2)`) is division, not a
  # segment separator. Empty segments (stray slashes) are dropped.
  defp split_top_level(string), do: split_top_level(string, 0, "", [])

  defp split_top_level(<<>>, _depth, current, acc), do: Enum.reverse(add_segment(current, acc))

  defp split_top_level(<<?(, rest::binary>>, depth, current, acc),
    do: split_top_level(rest, depth + 1, <<current::binary, ?(>>, acc)

  defp split_top_level(<<?), rest::binary>>, depth, current, acc),
    do: split_top_level(rest, max(depth - 1, 0), <<current::binary, ?)>>, acc)

  defp split_top_level(<<?/, rest::binary>>, 0, current, acc),
    do: split_top_level(rest, 0, "", add_segment(current, acc))

  defp split_top_level(<<c, rest::binary>>, depth, current, acc),
    do: split_top_level(rest, depth, <<current::binary, c>>, acc)

  defp add_segment("", acc), do: acc
  defp add_segment(segment, acc), do: [segment | acc]
end
