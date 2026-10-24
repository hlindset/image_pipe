Code.require_file("h.exs", __DIR__)
bytes = File.read!(System.get_env("F", Path.join(__DIR__, "src/cmyk_noicc.jpg")))
for g <- ["pad=5/bg=ff0000/format=png", "pad=5/bg=00ff00/format=png", "w=60/h=60/extend/bg=0000ff/format=png", "pad=5/bg=ffffff/format=png"] do
  {:ok, out} = H.request("/#{g}/src/x", H.opts(bytes, "image/jpeg")) |> H.decoded()
  IO.puts("#{g}: corner=#{inspect(Image.get_pixel!(out, 0, 0))}")
end
