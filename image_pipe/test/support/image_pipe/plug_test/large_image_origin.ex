defmodule ImagePipe.PlugTest.LargeImageOrigin do
  @moduledoc false
  # A valid JPEG one byte over the default body limit: beach.jpg padded with
  # comment segments after its start marker.
  @size 10_000_001
  @segment 65_537

  def call(conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body())
  end

  defp body do
    <<0xFF, 0xD8, rest::binary>> = File.read!("priv/static/images/beach.jpg")
    padding = @size - 2 - byte_size(rest)
    full = div(padding - 4, @segment)
    IO.iodata_to_binary([<<0xFF, 0xD8>>, comments(full, padding - full * @segment), rest])
  end

  defp comments(full, last), do: [List.duplicate(comment(@segment), full), comment(last)]

  defp comment(size), do: [<<0xFF, 0xFE, size - 2::16>>, :binary.copy(<<0>>, size - 4)]
end
