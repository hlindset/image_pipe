defmodule ImagePipe.Output.Negotiation do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Output.Capabilities
  alias Plug.Conn.Utils

  @modern_mime_types Map.new(Format.output_mime_types()) |> Map.take(Format.modern_formats())
  @modern_mime_type_list Map.values(@modern_mime_types)

  # Server preference order; hosts may override it with `:format_order`.
  @default_order [:avif, :webp]

  # `writable` is the formats the libvips build can write.
  @spec modern_candidates(String.t() | nil, keyword(), [atom()]) :: [:avif | :webp]
  def modern_candidates(accept_header, opts \\ [], writable \\ Capabilities.writable()) do
    case parse_accept(accept_header) do
      [] ->
        []

      entries ->
        opts
        |> enabled_modern_formats(writable)
        |> Enum.flat_map(&modern_candidate(&1, entries))
    end
  end

  # Whether `Accept` can change the format at all, which decides `Vary: Accept`.
  @spec negotiable?(keyword(), [atom()]) :: boolean()
  def negotiable?(opts, writable \\ Capabilities.writable()),
    do: enabled_modern_formats(opts, writable) != []

  defp enabled_modern_formats(opts, writable) do
    opts
    |> server_order()
    |> Enum.filter(&(&1 in writable and config_enabled?(&1, opts)))
    |> Enum.map(&{&1, Map.fetch!(@modern_mime_types, &1)})
  end

  # A partial `:format_order` prioritizes the listed formats, then appends any
  # unlisted modern formats in the default order. Validation that the list holds
  # only distinct known formats lives at the mount-config boundary.
  defp server_order(opts) do
    case Keyword.get(opts, :format_order) do
      order when is_list(order) and order != [] -> order ++ (@default_order -- order)
      _ -> @default_order
    end
  end

  # A modern format is a candidate only when it is config-enabled AND the libvips
  # build can actually write it. Capability filtering here flows identically to
  # resolution, the cache key, and conditional-GET, since all three use it.
  defp config_enabled?(:avif, opts), do: Keyword.get(opts, :auto_avif, true)
  defp config_enabled?(:webp, opts), do: Keyword.get(opts, :auto_webp, true)

  defp modern_candidate({format, mime_type}, entries) do
    if acceptable?(mime_type, entries), do: [format], else: []
  end

  # Modern formats require an explicit MIME type in Accept, and an explicit
  # q=0 wins over duplicate positive entries for the same MIME type.
  defp acceptable?(mime_type, entries) do
    case for({^mime_type, zero?} <- entries, do: zero?) do
      [] -> false
      zeros -> not Enum.any?(zeros)
    end
  end

  defp parse_accept(nil), do: []

  # Keeps only the entries for modern MIME types, as `{mime_type, zero?}`.
  defp parse_accept(accept_header) do
    for entry <- split_entries(accept_header),
        {:ok, type, subtype, params} <- [Utils.media_type(entry)],
        mime_type = type <> "/" <> subtype,
        mime_type in @modern_mime_type_list,
        do: {mime_type, zero_quality?(params)}
  end

  # Splits on commas outside quoted parameter values, which `Plug.Conn.Utils.list/1`
  # would split inside. Quotes toggle like Plug's own parameter split, without
  # backslash escapes.
  defp split_entries(header), do: split_entries(header, false, "", [])

  defp split_entries(<<?", rest::binary>>, quoted?, entry, acc),
    do: split_entries(rest, not quoted?, entry <> "\"", acc)

  defp split_entries(<<?,, rest::binary>>, false, entry, acc),
    do: split_entries(rest, false, "", push_entry(entry, acc))

  defp split_entries(<<char, rest::binary>>, quoted?, entry, acc),
    do: split_entries(rest, quoted?, <<entry::binary, char>>, acc)

  defp split_entries(<<>>, _quoted?, entry, acc), do: Enum.reverse(push_entry(entry, acc))

  defp push_entry(entry, acc) do
    case String.trim(entry) do
      "" -> acc
      entry -> [entry | acc]
    end
  end

  # RFC 9110 §12.4.2: qvalue = ( "0" [ "." 0*3DIGIT ] ) / ( "1" [ "." 0*3("0") ] )
  #
  # Only a well-formed zero excludes. An invalid or out-of-range weight
  # (`q=1.5`, `q=abc`) is ignored and counts as the default q=1, and any other
  # valid weight is positive.
  defp zero_quality?(%{"q" => value}),
    do: String.trim(value) in ["0", "0.", "0.0", "0.00", "0.000"]

  defp zero_quality?(_params), do: false
end
