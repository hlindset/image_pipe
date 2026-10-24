# usage: mix run run.exs ROOT FILE PIPELINE [PIPELINE...]
[root, file | pipelines] = System.argv()
import Plug.Test
opts =
  ImagePipe.Plug.init(
    allow_unsigned: true,
    sources: [
      f: [adapter: ImagePipe.Source.File, match: [prefix: "f"], options: [root: root, root_id: "fz"]]
    ]
  )

for p <- pipelines do
  path = if p == "", do: "/src/f/#{file}", else: "/#{p}/src/f/#{file}"
  t0 = System.monotonic_time(:millisecond)
  {status, body, ct} =
    try do
      conn = conn(:get, path) |> ImagePipe.Plug.call(opts)
      {conn.status, conn.resp_body || "", Plug.Conn.get_resp_header(conn, "content-type") |> List.first()}
    rescue
      e -> {:raised, Exception.format(:error, e, __STACKTRACE__) |> String.slice(0, 600), nil}
    catch
      k, v -> {:caught, inspect({k, v}) |> String.slice(0, 600), nil}
    end
  dt = System.monotonic_time(:millisecond) - t0
  extra =
    cond do
      is_integer(status) and status == 200 and ct && String.starts_with?(ct, "image/") ->
        case Vix.Vips.Image.new_from_buffer(body) do
          {:ok, img} -> "#{Image.width(img)}x#{Image.height(img)}b#{Image.bands(img)}"
          {:error, e} -> "UNDECODABLE_OUT:#{inspect(e)}"
        end
      is_integer(status) -> body |> to_string() |> String.slice(0, 160) |> String.replace("\n", " ")
      true -> body
    end
  IO.puts("RESULT\t#{file}\t#{p}\t#{inspect(status)}\t#{dt}ms\t#{byte_size(to_string(body))}\t#{extra}")
end
