defmodule ImagePipe.Dialect.Native.Path do
  @moduledoc """
  Raw request path → structured, byte-spanned segments for the native URL
  dialect [native §URL anatomy, §Byte-level contract].

  Produces two surfaces because signature verification must precede ALL
  parsing [native §Signing: "verify first, parse second, with zero
  scanning"]:

    * `split_signature/1` — raw byte inspection only. Strips the mount
      prefix, peels a leading `sig=` value if present, and returns
      `{sig, signed_path}`. No segment validation, no percent handling, no
      diagnostics. This is the only interpreter of the raw prefix; it never
      errors and never allocates diagnostics, so it is safe to call before
      any verification has happened.
    * `extract/1` — full lexing with spans and decoding. Must only be called
      after `Signature.verify/3` has succeeded against the same conn's
      `split_signature/1` output. It skips a leading `sig=` segment
      internally (without validating it — `split_signature/1` already did
      that job) but does not return signature data itself.

  Both functions compute the mount-relative raw path the same way: strip
  `conn.script_name` from `conn.request_path` as a raw string prefix. Since
  `script_name` is Plug's *decoded* segment list, this is only byte-exact
  when the mount path is canonical unescaped ASCII — see the moduledoc note
  on `ImagePipe.Dialect.Native` for the full caveat and the runtime raise
  this module performs when that invariant doesn't hold.

  All byte spans returned by `extract/1` are `{byte_offset, byte_length}`
  into the *mount-relative* raw path — the sig segment counts toward
  offsets even though it is skipped during lexing, so diagnostics can point
  at the right byte position in the actual request path.

  Lexing work is bounded: at most `@max_option_segments` segments (src/src64
  excepted) are lexed per request before giving up with a `:too_many_segments`
  diagnostic [native §Error diagnostics, bounded work] — a hostile path with
  an unbounded number of segments must not buy unbounded lexing work.
  """

  alias ImagePipe.Dialect.Native.Diagnostic

  @type span :: Diagnostic.span()

  @max_option_segments 64

  # Any "%" not followed by exactly two hex digits is a malformed escape.
  @malformed_percent ~r/%($|[^0-9A-Fa-f]|[0-9A-Fa-f]$|[0-9A-Fa-f][^0-9A-Fa-f])/

  @doc """
  Raw byte inspection only: strips the mount prefix from `conn.request_path`
  and, if the first mount-relative segment starts with `sig=`, returns its
  value and the raw remainder from the following `/` to end of path. Else
  returns `{nil, whole_mount_relative_path}`.

  Runs before verification: never validates segments, never percent-decodes,
  never returns an error tuple, never allocates a `Diagnostic`. The one
  exception is the mount-prefix canonicality raise (host misconfiguration,
  500-class, documented on the module) — that is not part of this
  function's `{sig, path}` contract.
  """
  @spec split_signature(Plug.Conn.t()) :: {sig :: String.t() | nil, signed_path :: String.t()}
  def split_signature(%Plug.Conn{} = conn) do
    path = mount_relative_path!(conn)

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

  @doc """
  Full lexing of the mount-relative raw path into option/flag/then segments
  plus a terminal source, called only after `Signature.verify/3` has
  succeeded. Skips a leading `sig=` segment internally (without validating
  it) but never returns signature data — `split_signature/1` is the raw
  prefix's only interpreter.

  Returns `{:ok, %{segments: [{raw, span}], source: {:src | :src64, decoded_tail, span}}}`
  on success, where `decoded_tail` is the fully decoded source string
  (percent-decoded once for `src`, base64url-decoded for `src64`) — both
  marker forms feed the same downstream source-resolution toolkit [native
  §Sources].

  On failure returns `{:error, [Diagnostic.t()]}` — errors accumulate
  across independent rule violations in a single pass.
  """
  @spec extract(Plug.Conn.t()) ::
          {:ok,
           %{
             segments: [{raw :: String.t(), span()}],
             source: {:src | :src64, decoded_tail :: String.t(), span()}
           }}
          | {:error, [Diagnostic.t()]}
  def extract(%Plug.Conn{} = conn) do
    path = mount_relative_path!(conn)

    query_errors =
      if conn.query_string != "" do
        [diagnostic(:non_empty_query_string, {byte_size(path), 0})]
      else
        []
      end

    lex_segments(path, lex_start(path), [], query_errors, 0)
  end

  # -- mount-prefix stripping -------------------------------------------

  defp mount_relative_path!(%Plug.Conn{request_path: request_path, script_name: script_name}) do
    prefix = mount_prefix!(script_name)

    case strip_prefix(request_path, prefix) do
      {:ok, rest} ->
        rest

      :error ->
        raise ArgumentError,
              "ImagePipe.Dialect.Native: request_path #{inspect(request_path)} does not " <>
                "start with the mount prefix #{inspect(prefix)} derived from script_name " <>
                "#{inspect(script_name)}"
    end
  end

  defp mount_prefix!([]), do: ""

  defp mount_prefix!(segments) do
    Enum.map_join(segments, "", fn segment ->
      if canonical_mount_segment?(segment) do
        "/" <> segment
      else
        raise ArgumentError,
              "ImagePipe.Dialect.Native: mount path segment #{inspect(segment)} is not " <>
                "canonical unescaped ASCII (non-canonical/escaped mount paths are " <>
                "unsupported in v1; a config-supplied raw mount prefix is a future " <>
                "escape hatch)"
      end
    end)
  end

  # A segment built only from RFC 3986 unreserved characters is guaranteed
  # byte-identical between conn.request_path (raw) and conn.script_name
  # (decoded) — those characters are never percent-encoded by a canonical
  # client. Anything else (including "%" itself) makes the round trip
  # through percent-encoding ambiguous, so it's rejected.
  defp canonical_mount_segment?(segment) do
    segment != "" and
      segment
      |> :binary.bin_to_list()
      |> Enum.all?(&mount_unreserved_byte?/1)
  end

  defp mount_unreserved_byte?(byte) do
    byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in [?-, ?., ?_, ?~]
  end

  defp strip_prefix(request_path, prefix) do
    if String.starts_with?(request_path, prefix) do
      {:ok,
       binary_part(request_path, byte_size(prefix), byte_size(request_path) - byte_size(prefix))}
    else
      :error
    end
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

  # -- sig-segment skip (extract/1 only) ---------------------------------

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
  # `segment_count` bounds lexing work [native §Error diagnostics, bounded
  # work]: it counts every non-terminal segment consumed (option, flag,
  # `then`, and every error-producing segment alike) but never the
  # terminal src/src64 marker itself, so a request genuinely at the option
  # budget can still reach its source.

  defp lex_segments(path, rest, segments_acc, errors_acc, segment_count) do
    case split_first_segment(rest) do
      {nil, _offset, _remainder} ->
        {:error, errors_acc ++ [diagnostic(:missing_source_marker, {byte_size(path), 0})]}

      {segment, _local_offset, remainder} ->
        segment_offset = byte_size(path) - byte_size(rest) + 1
        segment_len = byte_size(segment)

        cond do
          segment in ["src", "src64"] ->
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

  defp percent_decode(value) do
    if Regex.match?(@malformed_percent, value) do
      {:error, :malformed_percent_escape}
    else
      {:ok, URI.decode(value)}
    end
  end

  # -- diagnostics ----------------------------------------------------------

  defp diagnostic(reason, span) do
    %Diagnostic{reason: reason, message: message_for(reason), spans: [span]}
  end

  defp message_for(:non_empty_query_string), do: "query strings are not supported"
  defp message_for(:sig_only_valid_first), do: "sig must be the first segment"
  defp message_for(:missing_source_marker), do: "missing src or src64 marker"
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
end
