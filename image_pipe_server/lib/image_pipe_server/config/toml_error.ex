defmodule ImagePipeServer.Config.TomlError do
  @moduledoc """
  Rewrites the TOML parser's error message so it never shows a value.

  The parser quotes the offending line and, for some errors, the offending
  token. A file that fails to parse gives no tree to tell secrets apart, so
  every value is redacted: the quoted line keeps its key (or table header) and
  loses the rest, and quoted tokens and bytes in the summary are replaced. Key
  paths the parser quotes stay. A line inside a multi-line string or array is
  all value, so it keeps nothing. The caret moves to the placeholder when it
  pointed into the redacted part.
  """

  @placeholder "<redacted value>"
  @indent "    "
  @header ~r/\A\s*\[\[?[A-Za-z0-9_.\- ]*\]{0,2}\s*\z/
  @key ~r/\A\s*[A-Za-z0-9_\-."' ]+?\s*=\s*/
  @caret ~r/\A\s*\^ at column (\d+)\z/

  @doc "Formats the parser's `reason` for the file at `path`, which holds `contents`."
  @spec message(String.t(), Path.t(), String.t()) :: String.t()
  def message(reason, path, contents) do
    location = " in #{Path.relative_to_cwd(path)} on line "

    with [summary, context] <- String.split(reason, ":\n", parts: 2),
         [problem, line] <- String.split(summary, location, parts: 2),
         {:ok, source, column} <- source_and_column(context) do
      {redacted, caret} = redact_line(source, column, statement_start?(contents, source, line))

      "invalid TOML: #{redact_tokens(problem)}#{location}#{line}, column #{column}:\n\n" <>
        @indent <> redacted <> "\n" <> @indent <> String.duplicate(" ", caret) <> "^"
    else
      _unrecognized -> "invalid TOML: #{reason |> first_line() |> redact_tokens()}"
    end
  end

  defp source_and_column(context) do
    lines = context |> String.trim_leading("\n") |> String.split("\n")

    with [source | rest] <- lines,
         [column] <- Enum.find_value(rest, &Regex.run(@caret, &1, capture: :all_but_first)) do
      {:ok, String.replace_prefix(source, @indent, ""), String.to_integer(column)}
    else
      _unrecognized -> :error
    end
  end

  # The parser stops at the first error, so the lines before the quoted line
  # parse on their own exactly when it starts a new statement. An error at a
  # line's end is reported on the next line number.
  defp statement_start?(contents, source, line) do
    lines = contents |> String.split(["\r\n", "\n"]) |> Enum.take(String.to_integer(line))

    case lines |> Enum.with_index() |> Enum.filter(fn {text, _index} -> text == source end) do
      [] ->
        false

      found ->
        {_text, index} = List.last(found)
        match?({:ok, _tree}, lines |> Enum.take(index) |> Enum.join("\n") |> Toml.decode())
    end
  end

  defp redact_line(source, column, statement_start?) do
    kept =
      cond do
        not statement_start? -> leading_whitespace(source)
        Regex.match?(@header, source) -> source
        match = Regex.run(@key, source) -> hd(match)
        true -> leading_whitespace(source)
      end

    redacted = if kept == source, do: source, else: kept <> @placeholder
    # The parser reports column 0 for an error at a line's start.
    offset = max(column - 1, 0)
    {redacted, if(offset < String.length(kept), do: offset, else: String.length(kept))}
  end

  defp leading_whitespace(source) do
    [whitespace] = Regex.run(~r/\A\s*/, source)
    whitespace
  end

  # A token from the file follows one of these phrases and runs to the end of
  # the problem. It can hold quotes itself, so nothing after the phrase stays.
  @token_phrases ["invalid token ", "unexpected token ", ", but got ", "table array name at "]

  # `key in path '...'` names a key. Any other quote or byte list starts data.
  defp redact_tokens("cannot redefine key in path " <> _key = problem), do: problem

  defp redact_tokens(problem) do
    case :binary.match(problem, @token_phrases) do
      {start, length} -> binary_part(problem, 0, start + length) <> @placeholder
      :nomatch -> redact_from_quote(problem)
    end
  end

  defp redact_from_quote(problem) do
    case :binary.match(problem, ["'", "\"", "<<"]) do
      {start, _length} -> binary_part(problem, 0, start) <> @placeholder
      :nomatch -> problem
    end
  end

  defp first_line(reason), do: reason |> String.split(":\n", parts: 2) |> hd()
end
