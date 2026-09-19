defmodule ImagePipeFiddle.APIPath do
  @moduledoc false

  alias ImagePipe.API
  alias ImagePipe.API.Signature

  @signed_prefix "/image-signed"

  @spec protect(term(), term(), keyword()) :: {:ok, String.t()} | {:error, :invalid_request}
  def protect(tail, "signed", config) when is_binary(tail) do
    with {:ok, path} <- request_path(tail) do
      {:ok, signed_url(path, config)}
    end
  end

  def protect(tail, "signed-concealed", config) when is_binary(tail) do
    with {:ok, path} <- request_path(tail),
         {:ok, prefix, source} <- split_source(path),
         {:ok, decoded_source} <- decode_source(source),
         {:ok, token} <- API.encrypt_source(decoded_source, config) do
      {:ok, signed_url([prefix, "/enc/", token] |> IO.iodata_to_binary(), config)}
    else
      _error -> {:error, :invalid_request}
    end
  end

  def protect(_tail, _protection, _config), do: {:error, :invalid_request}

  defp request_path(""), do: {:error, :invalid_request}
  defp request_path("/" <> _rest), do: {:error, :invalid_request}

  defp request_path(tail) do
    case String.contains?(tail, ["?", "#"]) do
      true -> {:error, :invalid_request}
      false -> {:ok, "/" <> tail}
    end
  end

  defp split_source(path) do
    case String.split(path, "/src/", parts: 2) do
      [prefix, source] when source != "" -> {:ok, prefix, source}
      _parts -> {:error, :invalid_request}
    end
  end

  defp decode_source(source) do
    decoded = URI.decode(source)
    if String.valid?(decoded), do: {:ok, decoded}, else: {:error, :invalid_request}
  rescue
    ArgumentError -> {:error, :invalid_request}
  end

  defp signed_url(path, config) do
    signature = Signature.sign(path, config)
    IO.iodata_to_binary([@signed_prefix, "/sig=", signature, path])
  end
end
