Code.require_file("h.exs", __DIR__)

src = System.get_env("SRC")
{bytes, ct} =
  case src do
    nil -> {Image.write!(H.noise(37, 53), :memory, suffix: ".png"), "image/png"}
    path -> {File.read!(path), System.get_env("CT", "image/jpeg")}
  end

for g <- System.argv() do
  path = "/#{g}/src/x"
  conn = H.request(path, H.opts(bytes, ct))

  case H.decoded(conn) do
    {:ok, img} ->
      IO.puts("#{g} => 200 #{Image.width(img)}x#{Image.height(img)} bands=#{Image.bands(img)} #{inspect(Vix.Vips.Image.format(img))} #{inspect(Vix.Vips.Image.interpretation(img))}")

    {:error, st, body} ->
      IO.puts("#{g} => #{st} #{String.slice(body, 0, 300)}")
  end
end
