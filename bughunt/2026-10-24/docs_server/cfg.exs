d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 300) |> String.slice(0, 400)}") end
src = [sources: [m: [adapter: ImagePipe.Source.File, match: :path, options: [root: d <> "/imgs", root_id: "m"]]]]
p.("wm Upper", fn -> ImagePipe.config(src ++ [watermarks: %{Logo: [source: "photo.jpg"]}]); :ok end)
p.("wm opacity 0", fn -> ImagePipe.config(src ++ [watermarks: %{logo: [source: "photo.jpg", opacity: 0]}]); :ok end)
p.("wm opacity 1.5", fn -> ImagePipe.config(src ++ [watermarks: %{logo: [source: "photo.jpg", opacity: 1.5]}]); :ok end)
p.("autoq target 0", fn -> ImagePipe.config(autoquality_target: 0); :ok end)
p.("autoq target 100", fn -> ImagePipe.config(autoquality_target: 100); :ok end)
p.("svg opt without pkg?", fn -> ImagePipe.config(svg: [max_bytes: 5]); :ok end)
p.("request_defaults with preset", fn -> ImagePipe.config(request_defaults: "preset=x", presets: %{"x" => "w=10"}); :ok end)
p.("request_defaults two groups", fn -> ImagePipe.config(request_defaults: "w=10/-/h=10"); :ok end)
b = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 10000, enlarge: true])
p.("max_result_width", fn -> {:ok, r} = ImagePipe.run(ImagePipe.config(), b, {:file, d <> "/imgs/photo.jpg"}); {r.width, r.height, r.degraded?} end)
p.("unknown option", fn -> ImagePipe.config(foo: 1) end)
p.("cred msg", fn -> ImagePipe.config(sources: [s: [adapter: ImagePipe.Source.S3, match: {:scheme, "s3"}, options: [default: [region: "r", endpoint: "https://x.com", credentials: {:static, [access_key_id: "AKIASECRET", secret_access_key: 5]}]]]]) end)
