defmodule ImagePipeServer.Config.TomlError do
  @moduledoc """
  Rewrites the TOML parser's error message so it never shows a value.

  The parser quotes the offending line and, for some errors, the offending
  token. A file that fails to parse gives no tree to tell secrets apart, so
  every value is redacted: the quoted line keeps its key (or table header) and
  loses the rest, and quoted tokens in the summary are replaced. Key paths the
  parser quotes stay. The caret moves to the placeholder when it pointed into
  the redacted part.
  """

  @placeholder "<redacted value>"
  @indent "    "
  @header ~r/\A\s*\[\[?[A-Za-z0-9_.\- ]*\]{0,2}\s*\z/
  @key ~r/\A\s*[A-Za-z0-9_\-."' ]+?\s*=\s*/
  @caret ~r/\A\s*\^ at column (\d+)\z/

  @doc "Formats the parser's `reason` for the file at `path`."
  @spec message(String.t(), Path.t()) :: String.t()
  def message(reason, path) do
    location = " in #{Path.relative_to_cwd(path)} on line "

    with [summary, context] <- String.split(reason, ":\n", parts: 2),
         [problem, line] <- String.split(summary, location, parts: 2),
         {:ok, source, column} <- source_and_column(context) do
      {redacted, caret} = redact_line(source, column)

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

  defp redact_line(source, column) do
    kept =
      cond do
        Regex.match?(@header, source) -> source
        match = Regex.run(@key, source) -> hd(match)
        true -> leading_whitespace(source)
      end

    redacted = if kept == source, do: source, else: kept <> @placeholder
    offset = column - 1
    {redacted, if(offset < String.length(kept), do: offset, else: String.length(kept))}
  end

  defp leading_whitespace(source) do
    [whitespace] = Regex.run(~r/\A\s*/, source)
    whitespace
  end

  # Quoted tokens are data; `key in path '...'` names a key.
  defp redact_tokens(problem) do
    Regex.replace(~r/(key in path )?'[^']*'/, problem, fn
      "key in path " <> _rest = key_path, _prefix -> key_path
      _token, _prefix -> @placeholder
    end)
  end

  defp first_line(reason), do: reason |> String.split(":\n", parts: 2) |> hd()
end
