Code.require_file("/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/h.exs")
base = [allow_unsigned: true, sources: [media: [adapter: ImagePipe.Source.File, match: :path, options: [root: H.root(), root_id: "media"]]]]
try_cfg = fn label, extra ->
  r = try do
    ImagePipe.config(Keyword.merge(base, extra)); "OK"
  rescue e -> "#{inspect e.__struct__}: #{Exception.message(e) |> String.slice(0, 200)}" end
  IO.puts("CFG #{label}: #{r}")
end
try_cfg.("unknown", presets: %{"a" => "preset=crad"})
try_cfg.("cycle", presets: %{"a" => "preset=b", "b" => "preset=a"})
try_cfg.("anchor+detect", presets: %{"a" => "anchor=left/detect=face"})
try_cfg.("wm unknown", presets: %{"a" => "wm=logo"})
try_cfg.("rd preset", presets: %{"a" => "w=1"}, request_defaults: "preset=a")
try_cfg.("rd multi-group", request_defaults: "w=1/-/h=1")
try_cfg.("bad name", presets: %{"a b" => "w=1"})
try_cfg.("name with dot", presets: %{"a.b_c-d" => "w=1"})
try_cfg.("name unset", presets: %{"unset" => "w=1"})
try_cfg.("src in fragment", presets: %{"a" => "w=1/src/x.png"})
try_cfg.("sig in fragment", presets: %{"a" => "sig=abc/w=1"})
try_cfg.("fit alone", presets: %{"a" => "fit=cover"})
try_cfg.("wm-enc no keys", presets: %{"a" => "wm-enc=abc"})
try_cfg.("builder preset", presets: %{"card" => ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])})
