alias ImagePipe.API.{Parser, Path}
alias ImagePipe.URL
parse = fn url ->
  {:ok, lexed} = Path.extract(url, "")
  Parser.parse(lexed, [])
end
try_out = fn label, fun ->
  try do
    b = fun.()
    v = URL.validate(b)
    case URL.url(b, "a.jpg") do
      {:ok, url} -> IO.puts("#{label}: validate=#{inspect(v, limit: 3)} url=#{url} parse=#{inspect(elem(parse.(url),0))} #{inspect(case parse.(url) do {:error, e} -> e; _ -> "" end, limit: 8)}")
      e -> IO.puts("#{label}: validate=#{inspect(v, limit: 3)} url error #{inspect e, limit: 5}")
    end
  rescue e -> IO.puts("#{label}: raised #{Exception.message(e)}")
  end
end
try_out.("jpeg []", fn -> URL.new() |> URL.output(jpeg_options: []) end)
try_out.("jpeg [:unset]", fn -> URL.new() |> URL.output(jpeg_options: [:unset]) end)
try_out.("jpeg [:unset, :unset]", fn -> URL.new() |> URL.output(jpeg_options: [:unset, :unset]) end)
try_out.("fq []", fn -> URL.new() |> URL.output(format_qualities: []) end)
try_out.("fq %{}", fn -> URL.new() |> URL.output(format_qualities: %{}) end)
try_out.("fq [:unset, webp: 80]", fn -> URL.new() |> URL.output(format_qualities: [:unset, webp: 80]) end)
try_out.("jpeg [:unset, quality: 80]", fn -> URL.new() |> URL.output(jpeg_options: [:unset, interlace: true]) end)
try_out.("jpeg [interlace: false]", fn -> URL.new() |> URL.output(jpeg_options: [interlace: false]) end)
try_out.("detect []", fn -> URL.new() |> URL.group(resize: [width: 10, height: 10, fit: :cover], anchor: :smart, detect: []) end)
try_out.("detect %{}", fn -> URL.new() |> URL.group(resize: [width: 10, height: 10, fit: :cover], anchor: :smart, detect: %{}) end)
try_out.("presets []", fn -> URL.new() |> URL.group(presets: [], blur: 1) end)
try_out.("presets [\"a,b\"]", fn -> URL.new() |> URL.group(presets: ["a,b"]) end)
try_out.("presets [\"unset\"]", fn -> URL.new() |> URL.group(presets: ["unset"]) end)
try_out.("watermark unset", fn -> URL.new() |> URL.group(watermark: "unset") end)
try_out.("filename unset", fn -> URL.new(filename: "unset") end)
try_out.("cb unset", fn -> URL.new(cachebuster: "unset") end)
try_out.("detect unset class", fn -> URL.new() |> URL.group(resize: [width: 10, height: 10, fit: :cover], anchor: :smart, detect: ["unset"]) end)
try_out.("detect class with colon", fn -> URL.new() |> URL.group(resize: [width: 10, height: 10, fit: :cover], anchor: :smart, detect: ["a:b"]) end)
try_out.("wm-src64 unset", fn -> URL.new() |> URL.group(watermark_source: "unset") end)
try_out.("rotate 1e-300", fn -> URL.new() |> URL.group(rotate: 1.0e-300) end)
try_out.("rotate 359.99999999999994", fn -> URL.new() |> URL.group(rotate: 359.99999999999994) end)
try_out.("rotate -1e-300", fn -> URL.new() |> URL.group(rotate: -1.0e-300) end)
try_out.("dpr 5e-324", fn -> URL.new() |> URL.group(resize: [width: 10], dpr: 5.0e-324) end)
try_out.("crop 2147483647.5", fn -> URL.new() |> URL.group(crop: {2147483647.4, 10}) end)
try_out.("blur 1e-320", fn -> URL.new() |> URL.group(blur: 1.0e-320) end)
try_out.("sharpen 1e-6", fn -> URL.new() |> URL.group(sharpen: 0.000001) end)
try_out.("expires", fn -> URL.new(expires: 1) end)
try_out.("page 0", fn -> URL.new(page: 0) end)
