defmodule ImagePipe.Config.URL do
  @moduledoc false

  def extract!(options) do
    {base_url, options} = Keyword.pop(options, :base_url, "")
    {[base_url: base_url!(base_url)], options}
  end

  defp base_url!(value) when is_binary(value) do
    with {:ok, uri} <- URI.new(value),
         true <- valid_authority?(uri),
         true <- is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo),
         false <- String.contains?(uri.path || "", "//"),
         true <- valid_path?(uri.path || "") do
      String.trim_trailing(value, "/")
    else
      _invalid -> invalid_base!()
    end
  end

  defp base_url!(_value), do: invalid_base!()

  defp valid_authority?(%URI{scheme: nil, host: nil, port: nil}), do: true

  defp valid_authority?(%URI{scheme: scheme, host: host})
       when scheme in ["http", "https"] and is_binary(host) and host != "",
       do: true

  defp valid_authority?(_uri), do: false

  defp valid_path?(path) do
    path
    |> String.trim_leading("/")
    |> String.trim_trailing("/")
    |> String.split("/")
    |> valid_segments?()
  end

  defp valid_segments?([""]), do: true

  defp valid_segments?(segments),
    do:
      Enum.all?(segments, &(&1 not in [".", ".."] and Regex.match?(~r/\A[A-Za-z0-9._~-]+\z/, &1)))

  defp invalid_base!,
    do:
      raise(
        ArgumentError,
        "base_url must be an HTTP(S) URL or canonical unescaped path prefix without credentials, query, or fragment"
      )
end
