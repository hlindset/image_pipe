defmodule ImagePipe.Dialect.Native.DiagnosticRenderer do
  @moduledoc """
  Renders an accumulated `[ImagePipe.Dialect.Native.Diagnostic.t()]` list
  into the compiler-style caret display used as the `400` response body
  for the native URL dialect [native §Error diagnostics].

  There is only ever one source line — the raw request path — so layout
  is a single-line, rustc-style cascade: diagnostics are ordered left to
  right by their leftmost span; every span gets a caret run on the
  underline row; each diagnostic gets exactly one label, anchored at its
  own leftmost span (a diagnostic with more than one span, e.g. a
  duplicate key, still gets exactly one label). Labels stack below the
  underline with the rightmost diagnostic's label closest to the carets —
  every diagnostic further left keeps a connecting `|` until its own row,
  so no two labels ever collide.

  Diagnostic work is bounded, so a hostile path can't buy disproportionate
  work:

    * at most #{16} diagnostics are rendered — further ones are
      summarized in a trailing count line;
    * the echoed path is capped at #{2048} bytes, truncated with a
      marker;
    * the whole rendered body is capped at #{8192} bytes, truncated with
      a marker.

  Truncation is byte-level, not codepoint-aware — a cut can in principle
  land inside a multi-byte UTF-8 sequence. That is an accepted trade-off
  for a defensive length cap on diagnostic text, not user-facing prose.
  """

  alias ImagePipe.Dialect.Native.Diagnostic

  @header "invalid transformation options"

  @max_diagnostics 16
  @max_echoed_path_bytes 2048
  @max_rendered_body_bytes 8192

  @path_truncation_marker "...[truncated]"
  @body_truncation_marker "\n...[truncated]"

  @doc """
  Renders `diagnostics` (in the order the caller accumulated them) against
  `raw_path` (the same mount-relative raw path the diagnostics' spans were
  computed against).
  """
  @spec render(String.t(), [Diagnostic.t()]) :: iodata()
  def render(raw_path, diagnostics) when is_binary(raw_path) and is_list(diagnostics) do
    {kept, omitted_count} = cap_diagnostics(diagnostics)
    {path_text, truncated?} = truncate_path(raw_path)
    echoed_line = if truncated?, do: path_text <> @path_truncation_marker, else: path_text
    width = byte_size(path_text)

    lines =
      [@header, "", echoed_line] ++
        cascade_lines(width, kept) ++
        omitted_lines(omitted_count)

    lines
    |> Enum.map(&(&1 <> "\n"))
    |> IO.iodata_to_binary()
    |> truncate_body()
  end

  # -- bounded work: caps -------------------------------------------------

  defp cap_diagnostics(diagnostics) do
    total = length(diagnostics)

    if total > @max_diagnostics do
      {Enum.take(diagnostics, @max_diagnostics), total - @max_diagnostics}
    else
      {diagnostics, 0}
    end
  end

  defp truncate_path(raw_path) do
    if byte_size(raw_path) > @max_echoed_path_bytes do
      {binary_part(raw_path, 0, @max_echoed_path_bytes), true}
    else
      {raw_path, false}
    end
  end

  defp truncate_body(body) do
    if byte_size(body) > @max_rendered_body_bytes do
      allowed = @max_rendered_body_bytes - byte_size(@body_truncation_marker)
      binary_part(body, 0, allowed) <> @body_truncation_marker
    else
      body
    end
  end

  defp omitted_lines(0), do: []
  defp omitted_lines(count), do: ["#{count} further errors omitted"]

  # -- single-line cascade layout ------------------------------------------

  defp cascade_lines(_width, []), do: []

  defp cascade_lines(width, diagnostics) do
    ordered = Enum.sort_by(diagnostics, &anchor/1)

    [caret_line(ordered, width) | resolve_rows(ordered, width)]
  end

  # A diagnostic's label is anchored at its leftmost span, even when it
  # carries more than one (duplicate key, exclusive pair) — every span
  # still gets a caret run on the underline row via `caret_line/2`.
  defp anchor(%Diagnostic{spans: spans}) do
    spans |> Enum.map(&elem(&1, 0)) |> Enum.min()
  end

  defp caret_line(ordered, width) do
    placements =
      Enum.flat_map(ordered, fn %Diagnostic{spans: spans} ->
        Enum.flat_map(spans, &clipped_caret(&1, width))
      end)

    place(width, placements)
  end

  # Unlike a label (which may legitimately run past the path's own byte
  # length), a caret run underlines specific path bytes — clip it so a
  # span reaching past a truncated echoed path never grows carets into
  # the truncation marker.
  defp clipped_caret({offset, _len}, width) when offset >= width, do: []

  defp clipped_caret({offset, len}, width) do
    [{offset, String.duplicate("^", min(len, width - offset))}]
  end

  # One "all bars" connector row, then one row per diagnostic, closest
  # (rightmost) first: each row prints that diagnostic's message at its
  # anchor and a `|` for every diagnostic still waiting further left.
  defp resolve_rows(ordered, width) do
    resolve_order = Enum.reverse(ordered)

    {rows, _remaining} =
      Enum.map_reduce(resolve_order, ordered, fn target, remaining ->
        {message_row(remaining, target, width), List.delete(remaining, target)}
      end)

    [bar_row(ordered, width) | rows]
  end

  defp bar_row(ordered, width) do
    placements = Enum.map(ordered, &{anchor(&1), "|"})
    place(width, placements)
  end

  defp message_row(remaining, target, width) do
    placements =
      Enum.map(remaining, fn diag ->
        if diag == target do
          {anchor(diag), diag.message}
        else
          {anchor(diag), "|"}
        end
      end)

    place(width, placements)
  end

  # Lays out non-overlapping {column, text} placements left to right,
  # padding gaps with spaces. A placement starting at or past `width` is
  # dropped (its diagnostic points past a truncated echoed path); text
  # itself is never clipped here — only a caret run's *length* is
  # boundary-sensitive (see `clipped_caret/2`), a label may legitimately
  # run past the path's own byte length.
  defp place(width, placements) do
    placements
    |> Enum.filter(fn {col, _text} -> col < width end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce({0, []}, fn {col, text}, {cursor, acc} ->
      col = max(col, cursor)
      pad = String.duplicate(" ", col - cursor)
      {col + byte_size(text), [text, pad | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end
end
