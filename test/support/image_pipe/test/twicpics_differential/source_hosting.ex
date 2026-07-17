defmodule ImagePipe.Test.TwicpicsDifferential.SourceHosting do
  @moduledoc """
  Verifies that a committed differential source and the object TwicPics renders
  are the same image.

  A missing URL pair is a two-run bootstrap: upload once, print the inventory
  fields, and stop. A bake can proceed only after both values are committed to
  `SourceInventory` and verified on the next run.
  """
  use Boundary, top_level?: true, check: [out: false]

  alias Vix.Vips.Image, as: VipsImage

  @direct_host "files.catbox.moe"
  @hosted_host "imagepipe.twic.pics"
  @identity_query "?twic=v1/output=png"

  @type environment :: %{
          upload: (Path.t(), map() -> {String.t(), String.t()}),
          fetch: (String.t() -> {:ok, binary()} | {:error, term()}),
          info: (String.t() -> :ok)
        }

  @doc """
  Resolves one source inventory entry or raises before fixture generation.

  Complete entries verify the direct object hash and the decoded TwicPics
  identity render. Empty entries upload once and raise with the two values that
  must be committed before a second run.
  """
  @spec resolve!(map(), Path.t(), environment()) :: %{
          hosted_url: String.t(),
          sha256: String.t()
        }
  def resolve!(%{hosted_url: nil, source_bytes_url: nil} = entry, source_path, env) do
    {source_bytes_url, hosted_url} = env.upload.(source_path, entry)
    validate_url_pair!(source_bytes_url, hosted_url)
    env.info.("source_bytes_url: #{inspect(source_bytes_url)}")
    env.info.("hosted_url: #{inspect(hosted_url)}")

    Mix.raise(
      "source #{entry.file}: upload complete; record both URLs in SourceInventory and rerun"
    )
  end

  def resolve!(%{hosted_url: hosted_url, source_bytes_url: source_bytes_url} = entry, _path, _env)
      when is_nil(hosted_url) or is_nil(source_bytes_url) do
    Mix.raise("source #{entry.file}: incomplete source-hosting metadata")
  end

  def resolve!(
        %{hosted_url: hosted_url, source_bytes_url: source_bytes_url} = entry,
        source_path,
        env
      ) do
    validate_url_pair!(source_bytes_url, hosted_url)
    committed = File.read!(source_path)
    committed_sha256 = sha256(committed)
    direct = fetch!(env, source_bytes_url, entry.file)
    verify_direct_hash!(entry, source_bytes_url, committed_sha256, direct)

    identity_url = hosted_url <> @identity_query
    identity = fetch!(env, identity_url, entry.file)
    verify_identity!(entry, source_path, identity)

    %{sha256: committed_sha256, hosted_url: hosted_url}
  end

  defp validate_url_pair!(source_bytes_url, hosted_url)
       when is_binary(source_bytes_url) and is_binary(hosted_url) do
    direct = URI.parse(source_bytes_url)
    hosted = URI.parse(hosted_url)
    direct_basename = valid_url_basename(direct, @direct_host)
    hosted_basename = valid_url_basename(hosted, @hosted_host)

    case {direct_basename, hosted_basename} do
      {basename, basename} when is_binary(basename) -> :ok
      _ -> Mix.raise("invalid source-hosting URL pair")
    end
  end

  defp validate_url_pair!(_source_bytes_url, _hosted_url),
    do: Mix.raise("invalid source-hosting URL pair")

  defp valid_url_basename(
         %URI{
           scheme: "https",
           authority: host,
           host: host,
           userinfo: nil,
           query: nil,
           fragment: nil,
           path: path
         },
         host
       )
       when is_binary(path) do
    case String.split(path, "/", trim: true) do
      [] -> nil
      parts -> valid_basename(List.last(parts))
    end
  end

  defp valid_url_basename(_uri, _host), do: nil

  defp valid_basename(basename) when basename not in ["", ".", ".."], do: basename
  defp valid_basename(_basename), do: nil

  defp fetch!(env, url, file) do
    case env.fetch.(url) do
      {:ok, body} when is_binary(body) -> body
      {:error, reason} -> Mix.raise("source #{file}: fetch failed for #{url}: #{inspect(reason)}")
      other -> Mix.raise("source #{file}: invalid fetch result for #{url}: #{inspect(other)}")
    end
  end

  defp verify_direct_hash!(entry, url, committed_sha256, direct) do
    case sha256(direct) do
      ^committed_sha256 -> :ok
      _ -> Mix.raise("source #{entry.file}: hosted bytes (#{url}) differ from committed")
    end
  end

  defp verify_identity!(entry, source_path, identity_body) do
    with {:ok, source} <- Image.open(source_path, access: :random, fail_on: :error),
         {:ok, identity} <- Image.open([identity_body], access: :random, fail_on: :error),
         true <- same_image?(source, identity) do
      :ok
    else
      _ ->
        Mix.raise("source #{entry.file}: TwicPics identity render differs from committed source")
    end
  end

  defp same_image?(source, identity) do
    image_shape(source) == image_shape(identity) and pixels(source) == pixels(identity)
  end

  defp image_shape(image), do: {Image.width(image), Image.height(image), Image.bands(image)}

  defp pixels(image) do
    {:ok, pixels} = VipsImage.write_to_binary(image)
    pixels
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
end
