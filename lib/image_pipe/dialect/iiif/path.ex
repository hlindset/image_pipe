defmodule ImagePipe.Dialect.IIIF.Path do
  @moduledoc """
  Dispatches an IIIF request by exact `conn.path_info` segment count and
  reconstructs the absolute base URI (for the info.json `id` and base redirect).
  """

  @spec classify(Plug.Conn.t()) ::
          {:redirect, String.t(), String.t()}
          | {:info, String.t()}
          | {:image, String.t(), map()}
          | :not_found
  def classify(%Plug.Conn{path_info: [id]} = conn),
    do: {:redirect, decode(id), base_uri(conn) <> "/" <> id <> "/info.json"}

  def classify(%Plug.Conn{path_info: [id, "info.json"]}),
    do: {:info, decode(id)}

  def classify(%Plug.Conn{path_info: [id, region, size, rotation, quality_format]}) do
    # Percent-decode every token (not just the id): path_info segments may arrive
    # encoded (e.g. a browser sends `^` as `%5E`, `:` as `%3A`), and RFC 3986 requires
    # treating the encoded and literal forms identically. Split quality/format on the
    # structural `.` first, then decode each part, so an encoded `.` can't mis-split.
    case split_quality_format(quality_format) do
      {:ok, quality, format} ->
        {:image, decode(id),
         %{
           region: decode(region),
           size: decode(size),
           rotation: decode(rotation),
           quality: decode(quality),
           format: decode(format)
         }}

      :error ->
        :not_found
    end
  end

  def classify(%Plug.Conn{}), do: :not_found

  @doc "Absolute base URI up to and including the mount prefix (no trailing slash)."
  @spec base_uri(Plug.Conn.t()) :: String.t()
  def base_uri(%Plug.Conn{} = conn) do
    authority = conn.host <> port_suffix(conn.scheme, conn.port)
    prefix = Enum.map_join(conn.script_name, &("/" <> &1))
    "#{conn.scheme}://#{authority}#{prefix}"
  end

  defp split_quality_format(segment) do
    case String.split(segment, ".") do
      parts when length(parts) >= 2 ->
        format = List.last(parts)
        quality = parts |> Enum.drop(-1) |> Enum.join(".")
        if quality == "" or format == "", do: :error, else: {:ok, quality, format}

      _ ->
        :error
    end
  end

  # conn.scheme is an ATOM (:http | :https), not a string — match atoms so that
  # default-port URLs don't get a spurious ":80"/":443" suffix in info.json id
  # and 303 Location headers.
  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"

  defp decode(segment), do: URI.decode(segment)
end
