defmodule ImagePipe.Dialect.Imgproxy.ResponseMeta do
  @moduledoc false

  # The `%ImagePipe.Plan.Response{}` one imgproxy request delivers with — its
  # `Content-Disposition` filename, disposition, and the `debug?` opt-in.
  #
  # The dialect owns its whole request chain rather than depending on the
  # `ImagePipe.Parser` boundary the framework parsers (IIIF, TwicPics) use.
  # Split out of `ImagePipe.Dialect.Imgproxy` so the chain module itself
  # carries none of this derivation logic — the same split `Assembly` makes
  # for the geometry half.
  #
  # The `fn:`-less fallback is the reason this derives a struct rather than
  # reading a field: imgproxy names the delivered file after the SOURCE's
  # basename when the request does not, so every response carries a filename.
  # Building the struct straight from `request.response` would drop that on
  # every request.

  alias ImagePipe.Dialect.Imgproxy.Request
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.Reference
  alias ImagePipe.Plan.Source.URL

  @doc """
  The delivery metadata for `request` against its translated `plan_source`.

  Rejects an unusable `fn:` stem with `{:error, {:invalid_filename, stem}}`,
  reached before any source fetch by the dialect's chain.
  """
  @spec build(Request.t(), ImagePipe.Plan.Source.t()) ::
          {:ok, Response.t()} | {:error, {:invalid_filename, term()}}
  def build(%Request{response: response}, plan_source),
    do: response_plan(response, plan_source)

  defp response_plan(%{filename: nil, disposition: disposition, debug?: debug?}, source) do
    {:ok, %Response{filename: source_filename(source), disposition: disposition, debug?: debug?}}
  end

  defp response_plan(%{filename: filename, disposition: disposition, debug?: debug?}, _source)
       when is_binary(filename) do
    if Response.valid_filename?(filename) do
      {:ok, %Response{filename: filename, disposition: disposition, debug?: debug?}}
    else
      {:error, {:invalid_filename, filename}}
    end
  end

  defp source_filename(%Path{segments: segments}), do: filename_from_segments(segments)
  defp source_filename(%URL{path: path}), do: filename_from_segments(path)

  defp source_filename(%Object{key: key}) do
    key
    |> String.split("/", trim: true)
    |> filename_from_segments()
  end

  defp source_filename(%Reference{id: id}), do: valid_source_filename(id)
  defp source_filename(_source), do: "image"

  defp filename_from_segments(segments) do
    segments
    |> List.last()
    |> source_filename_stem()
    |> valid_source_filename()
  end

  defp source_filename_stem(basename) when basename in [nil, ""], do: "image"

  defp source_filename_stem(basename) when is_binary(basename) do
    case Elixir.Path.rootname(basename) do
      "" -> "image"
      stem -> stem
    end
  end

  defp valid_source_filename(stem) do
    if Response.valid_filename?(stem), do: stem, else: "image"
  end
end
