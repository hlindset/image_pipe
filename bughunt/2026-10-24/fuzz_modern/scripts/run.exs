# usage: mix run run.exs FILE [pipeline ...]
import Plug.Test
[file | pipes] = System.argv()
pipes = if pipes == [], do: ["", "w=300/", "crop=50pct,50pct/rotate=90/", "blur=5/", "pad=10/bg=00ff00/format=png/", "format=webp/", "format=avif/", "format=png/", "format=jpeg/"], else: pipes
dir = Path.dirname(Path.expand(file)); name = Path.basename(file)
config = ImagePipe.Plug.init(allow_unsigned: true,
  sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "fz"]]])
for p <- pipes do
  p = if p == "-", do: "", else: p
  t0 = System.monotonic_time(:millisecond)
  {res, conn} =
    try do
      c = conn(:get, "/" <> p <> "src/" <> URI.encode(name)) |> ImagePipe.Plug.call(config)
      {:ok, c}
    catch k, r -> {{k, r}, nil}
    end
  dt = System.monotonic_time(:millisecond) - t0
  case res do
    :ok ->
      ct = Plug.Conn.get_resp_header(conn, "content-type") |> List.first()
      info =
        if conn.status == 200 do
          case Image.from_binary(conn.resp_body) do
            {:ok, img} ->
              {w, h, b} = Image.shape(img)
              icc = case Vix.Vips.Image.header_value(img, "icc-profile-data") do {:ok, x} when is_binary(x) -> byte_size(x); _ -> 0 end
              px = fn x, y -> case Image.get_pixel(img, x, y) do {:ok, v} -> Enum.map(v, &round/1); e -> inspect(e) end end
              "#{w}x#{h}x#{b} #{Vix.Vips.Image.interpretation(img)} icc=#{icc} p00=#{inspect px.(0,0)} pc=#{inspect px.(div(w,2),div(h,2))}"
            e -> "UNDECODABLE #{inspect e}"
          end
        else
          String.slice(inspect(conn.resp_body), 0, 160)
        end
      IO.puts("[#{p}] #{conn.status} #{ct} #{byte_size(conn.resp_body)}B #{dt}ms #{info}")
    {k, r} -> IO.puts("[#{p}] RAISE #{inspect k} #{String.slice(inspect(r), 0, 300)} #{dt}ms")
  end
end
