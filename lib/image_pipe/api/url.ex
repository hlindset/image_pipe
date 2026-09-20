defmodule ImagePipe.API.URL do
  @moduledoc false

  alias ImagePipe.API.{Path, Serializer, Signature, SourceEncryption, URLConfig}
  alias ImagePipe.Plan

  def build(plan, source, %URLConfig{} = config, options) do
    with :ok <- source(source),
         {:ok, request} <- request(plan, source),
         {:ok, segments} <- segments(request),
         {:ok, source_segments} <- source_segments(source, config, options) do
      path = "/" <> Enum.join(segments ++ source_segments, "/")
      {:ok, config.base_url <> sign(path, config.keys)}
    end
  end

  defp source(source) when is_binary(source) and source != "" do
    case String.valid?(source) do
      true -> :ok
      false -> {:error, :invalid_source}
    end
  end

  defp source(_source), do: {:error, :invalid_source}

  defp source_segments(source, %URLConfig{encrypt_source: true} = config, options) do
    with {:ok, token} <- SourceEncryption.encrypt(source, config.source_encryption, options) do
      {:ok, ["enc", token]}
    end
  end

  defp source_segments(source, %URLConfig{encrypt_source: false}, []),
    do: {:ok, source_segments(source)}

  defp source_segments(_source, %URLConfig{encrypt_source: false}, _options),
    do: {:error, :source_encryption_disabled}

  # Browsers normalize dot path segments even when the dots are percent-encoded.
  defp source_segments(source) when source in [".", ".."],
    do: ["src64", Base.url_encode64(source, padding: false)]

  defp source_segments(source), do: ["src", URI.encode(source, &URI.char_unreserved?/1)]

  defp request(plan, source) do
    case Plan.to_request(plan, source) do
      {:ok, request} -> {:ok, request}
      {:error, issues} -> {:error, {:invalid_request, issues}}
    end
  end

  defp segments(request) do
    segments = Serializer.segments(request)

    case length(segments) <= Path.max_option_segments() do
      true -> {:ok, segments}
      false -> {:error, :too_many_options}
    end
  end

  defp sign(path, %{values: []}), do: path
  defp sign(path, keys), do: "/sig=" <> Signature.sign(path, keys: keys) <> path
end
