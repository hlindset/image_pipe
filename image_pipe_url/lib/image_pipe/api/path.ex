defmodule ImagePipe.API.Path do
  # Splits request paths into segments with byte spans.
  #
  # Signature verification must precede parsing:
  #
  #   * `split_signature/1` returns `{sig, signed_path}` using raw byte
  #     inspection only. It does not validate segments, decode escapes, or
  #     allocate diagnostics.
  #   * `extract/2` lexes and decodes only after `Signature.verify/3` succeeds
  #     against the same path's `split_signature/1` output. It skips the
  #     leading signature segment and returns no signature data.
  #
  # Both take the raw mount-relative path: `""` or a string starting with `/`,
  # with the mount prefix and query string already removed.
  #
  # Spans are `{byte_offset, byte_length}` into the mount-relative raw path,
  # including the skipped signature segment in their offsets.
  #
  # Lexing stops with `:too_many_segments` after `@max_option_segments`
  # non-source segments, bounding work on hostile paths.
  @moduledoc false

  alias ImagePipe.API.Diagnostic

  @type span :: Diagnostic.span()

  @max_option_segments 64

  @doc false
  def max_option_segments, do: @max_option_segments

  @doc """
  Raw byte inspection only: if the first segment of the mount-relative
  `path` starts with `sig=`, returns its value and the raw remainder from the
  following `/` to end of path. Else returns `{nil, path}`.

  Runs before verification without segment validation, percent-decoding,
  error tuples, or diagnostics.
  """
  @spec split_signature(String.t()) :: {sig :: String.t() | nil, signed_path :: String.t()}
  def split_signature(path) when is_binary(path) do
    case split_first_segment(path) do
      {nil, _offset, _remainder} ->
        {nil, path}

      {segment, _offset, remainder} ->
        if String.starts_with?(segment, "sig=") do
          {binary_part(segment, 4, byte_size(segment) - 4), remainder}
        else
          {nil, path}
        end
    end
  end

  @doc false
  @spec diagnostic_path(String.t()) :: String.t()
  def diagnostic_path(path) when is_binary(path) do
    case secret_ranges(path, 0, []) do
      [] -> path
      ranges -> path |> mask_ranges(0, Enum.reverse(ranges)) |> IO.iodata_to_binary()
    end
  end

  @doc """
  Full lexing of the mount-relative raw path and its query string into option/flag/separator segments
  plus a terminal source, called only after `Signature.verify/3` has
  succeeded. Skips a leading `sig=` segment internally (without validating
  it) but never returns signature data — `split_signature/1` is the raw
  prefix's only interpreter.

  Returns `{:ok, %{segments: [{raw, span}], source: {:src | :src64 | :enc, source, span}}}`
  on success. `src` is percent-decoded once, `src64` is base64url-decoded,
  and `enc` remains an opaque token for authenticated decryption by
  `ImagePipe.API`.

  On failure returns `{:error, [Diagnostic.t()]}` — errors accumulate
  across independent rule violations in a single pass.
  """
  @spec extract(String.t(), String.t()) ::
          {:ok,
           %{
             segments: [{raw :: String.t(), span()}],
             source: {:src | :src64 | :enc, decoded_tail :: String.t(), span()}
           }}
          | {:error, [Diagnostic.t()]}
  def extract(path, query_string) when is_binary(path) and is_binary(query_string) do
    query_errors =
      if query_string != "" do
        [diagnostic(:non_empty_query_string, {byte_size(path), 0})]
      else
        []
      end

    lex_segments(path, lex_start(path), [], query_errors, 0)
  end

  # -- shared raw segment splitting --------------------------------------

  # `path` is always "" or starts with "/". Returns the first segment (the
  # text between the leading "/" and the next "/" or end of string), the
  # byte offset that segment starts at (always 1 when non-nil, relative to
  # `path`'s own start), and the remainder ("" or starting with the next
  # "/"). Returns `{nil, 0, ""}` when `path` is "".
  defp split_first_segment(""), do: {nil, 0, ""}

  defp split_first_segment("/" <> after_slash) do
    case :binary.split(after_slash, "/") do
      [segment, rest] -> {segment, 1, "/" <> rest}
      [segment] -> {segment, 1, ""}
    end
  end

  # -- sig-segment skip (extract/2 only) ---------------------------------

  defp lex_start(path) do
    case split_first_segment(path) do
      {nil, _offset, _remainder} ->
        path

      {segment, _offset, remainder} ->
        if String.starts_with?(segment, "sig=") do
          remainder
        else
          path
        end
    end
  end

  # -- segment lexer -------------------------------------------------------
  #
  # Count every non-terminal segment, including invalid ones, to bound work.
  # Exclude src/src64/enc so a request at the option limit can reach its source.

  defp lex_segments(path, rest, segments_acc, errors_acc, segment_count) do
    case split_first_segment(rest) do
      {nil, _offset, _remainder} ->
        {:error, errors_acc ++ [diagnostic(:missing_source_marker, {byte_size(path), 0})]}

      {segment, _local_offset, remainder} ->
        segment_offset = byte_size(path) - byte_size(rest) + 1
        segment_len = byte_size(segment)

        cond do
          segment in ["src", "src64", "enc"] ->
            classify_segment(
              segment,
              path,
              remainder,
              segment_offset,
              segment_len,
              segments_acc,
              errors_acc,
              segment_count
            )

          segment_count >= @max_option_segments ->
            {:error, errors_acc ++ [diagnostic(:too_many_segments, {segment_offset, 0})]}

          true ->
            classify_segment(
              segment,
              path,
              remainder,
              segment_offset,
              segment_len,
              segments_acc,
              errors_acc,
              segment_count
            )
        end
    end
  end

  defp classify_segment(segment, path, remainder, offset, len, segments_acc, errors_acc, count) do
    cond do
      segment == "" ->
        continue(path, remainder, segments_acc, errors_acc, count, :empty_segment, {offset, 0})

      segment in [".", ".."] ->
        continue(path, remainder, segments_acc, errors_acc, count, :dot_segment, {offset, len})

      segment == "src" ->
        finish_source(:src, path, remainder, segments_acc, errors_acc)

      segment == "src64" ->
        finish_source(:src64, path, remainder, segments_acc, errors_acc)

      segment == "enc" ->
        finish_concealed_source(path, remainder, segments_acc, errors_acc)

      String.starts_with?(segment, "sig=") ->
        continue(
          path,
          remainder,
          segments_acc,
          errors_acc,
          count,
          :sig_only_valid_first,
          {offset, len}
        )

      String.contains?(segment, "%") ->
        continue(
          path,
          remainder,
          segments_acc,
          errors_acc,
          count,
          :percent_in_option_segment,
          {offset, len}
        )

      true ->
        lex_segments(
          path,
          remainder,
          segments_acc ++ [{segment, {offset, len}}],
          errors_acc,
          count + 1
        )
    end
  end

  defp continue(path, remainder, segments_acc, errors_acc, count, reason, span) do
    lex_segments(
      path,
      remainder,
      segments_acc,
      errors_acc ++ [diagnostic(reason, span)],
      count + 1
    )
  end

  # -- source marker (terminal) --------------------------------------------

  defp finish_concealed_source(path, remainder, segments_acc, errors_acc) do
    {tail, tail_offset} = concealed_tail(path, remainder)

    case errors_acc do
      [] -> {:ok, %{segments: segments_acc, source: {:enc, tail, {tail_offset, byte_size(tail)}}}}
      errors -> {:error, errors}
    end
  end

  defp concealed_tail(path, ""), do: {"", byte_size(path)}
  defp concealed_tail(path, "/" <> tail), do: {tail, byte_size(path) - byte_size(tail)}

  defp finish_source(marker, path, remainder, segments_acc, errors_acc) do
    case remainder do
      "" ->
        finish_error(:missing_source, byte_size(path), 0, errors_acc)

      "/" <> tail ->
        finish_source_tail(marker, path, tail, segments_acc, errors_acc)
    end
  end

  defp finish_source_tail(_marker, path, "", _segments_acc, errors_acc) do
    finish_error(:missing_source, byte_size(path), 0, errors_acc)
  end

  defp finish_source_tail(marker, path, tail, segments_acc, errors_acc) do
    tail_offset = byte_size(path) - byte_size(tail)
    tail_len = byte_size(tail)

    case decode_source_tail(marker, tail) do
      {:ok, decoded} ->
        if errors_acc == [] do
          {:ok, %{segments: segments_acc, source: {marker, decoded, {tail_offset, tail_len}}}}
        else
          {:error, errors_acc}
        end

      {:error, reason} ->
        finish_error(reason, tail_offset, tail_len, errors_acc)
    end
  end

  defp finish_error(reason, offset, len, errors_acc) do
    {:error, errors_acc ++ [diagnostic(reason, {offset, len})]}
  end

  defp decode_source_tail(:src, tail), do: percent_decode(tail)

  defp decode_source_tail(:src64, tail) do
    cond do
      String.contains?(tail, "/") -> {:error, :src64_embedded_slash}
      String.contains?(tail, "=") -> {:error, :src64_padding}
      true -> decode_base64(tail)
    end
  end

  defp decode_base64(tail) do
    case Base.url_decode64(tail, padding: false) do
      {:ok, decoded} -> {:ok, decoded}
      :error -> {:error, :invalid_base64}
    end
  end

  # -- percent-decoding (src tail only, exactly once) ----------------------

  # Checks and decodes in one pass. Any "%" not followed by exactly two hex
  # digits is a malformed escape.
  defp percent_decode(value) do
    case :binary.match(value, "%") do
      :nomatch ->
        {:ok, value}

      {at, 1} ->
        decode_escapes(binary_part(value, at, byte_size(value) - at), binary_part(value, 0, at))
    end
  end

  defguardp hex?(byte) when byte in ?0..?9 or byte in ?A..?F or byte in ?a..?f

  defp decode_escapes(<<?%, a, b, rest::binary>>, acc) when hex?(a) and hex?(b),
    do: decode_escapes(rest, <<acc::binary, hex_value(a) * 16 + hex_value(b)>>)

  defp decode_escapes(<<?%, _rest::binary>>, _acc), do: {:error, :malformed_percent_escape}

  defp decode_escapes(<<byte, rest::binary>>, acc),
    do: decode_escapes(rest, <<acc::binary, byte>>)

  defp decode_escapes(<<>>, acc), do: {:ok, acc}

  defp hex_value(byte) when byte in ?0..?9, do: byte - ?0
  defp hex_value(byte) when byte in ?A..?F, do: byte - ?A + 10
  defp hex_value(byte) when byte in ?a..?f, do: byte - ?a + 10

  # -- diagnostics ----------------------------------------------------------

  defp diagnostic(reason, span) do
    %Diagnostic{reason: reason, message: message_for(reason), spans: [span]}
  end

  defp message_for(:non_empty_query_string), do: "query strings are not supported"
  defp message_for(:sig_only_valid_first), do: "sig must be the first segment"

  defp message_for(:missing_source_marker),
    do: "missing src/, src64/, or enc/ before the image path"

  defp message_for(:missing_source), do: "missing source after src/src64 marker"
  defp message_for(:malformed_percent_escape), do: "malformed percent escape"
  defp message_for(:src64_embedded_slash), do: "src64 value may not contain a slash"
  defp message_for(:src64_padding), do: "src64 value may not be padded"
  defp message_for(:invalid_base64), do: "invalid base64url value"

  defp message_for(:percent_in_option_segment),
    do: "percent escapes are not allowed in option segments"

  defp message_for(:empty_segment), do: "empty path segment"
  defp message_for(:dot_segment), do: "dot segments are not allowed"

  defp message_for(:too_many_segments),
    do: "too many option segments (max #{@max_option_segments})"

  # The `{offset, length}` of each secret in `path`, last first. The walk
  # goes by byte offset, so each segment is a sub-binary of `path`.
  defp secret_ranges(path, position, ranges) when position < byte_size(path) do
    start = position + 1

    segment_end =
      case :binary.match(path, "/", scope: {start, byte_size(path) - start}) do
        {slash, 1} -> slash
        :nomatch -> byte_size(path)
      end

    case binary_part(path, start, segment_end - start) do
      marker when marker in ["src", "src64"] ->
        ranges

      "enc" when segment_end < byte_size(path) ->
        [{segment_end + 1, byte_size(path) - segment_end - 1} | ranges]

      "enc" ->
        ranges

      "sig=" <> signature ->
        secret_ranges(path, segment_end, [{start + 4, byte_size(signature)} | ranges])

      "wm-enc=" <> token ->
        secret_ranges(path, segment_end, [{start + 7, byte_size(token)} | ranges])

      _segment ->
        secret_ranges(path, segment_end, ranges)
    end
  end

  defp secret_ranges(_path, _position, ranges), do: ranges

  defp mask_ranges(path, position, [{offset, length} | ranges]) do
    [
      binary_part(path, position, offset - position),
      :binary.copy("*", length)
      | mask_ranges(path, offset + length, ranges)
    ]
  end

  defp mask_ranges(path, position, []),
    do: [binary_part(path, position, byte_size(path) - position)]
end
