alias ImagePipe.SVG
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e) |> String.slice(0, 200)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 200) |> String.slice(0, 300)}") end
d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
p.("versions", fn -> SVG.versions() end)
p.("load nodir", fn -> SVG.load_fonts([d <> "/nofonts"]) end)
File.mkdir_p!(d <> "/fonts")
{:ok, f} = SVG.load_fonts([d <> "/fonts"])
p.("fallback missing", fn -> SVG.load_fonts([d <> "/fonts"], fallback_family: "Nope") end)
File.write!(d <> "/fonts/bad.ttf", "notafont")
p.("bad font", fn -> SVG.load_fonts([d <> "/fonts"]) end)
File.rm!(d <> "/fonts/bad.ttf")
wrap = fn body -> ~s(<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="10" height="10">#{body}</svg>) end
deep = fn n -> String.duplicate("<g>", n) <> "<rect width='5' height='5'/>" <> String.duplicate("</g>", n) end
p.("nest 1000", fn -> SVG.parse(wrap.(deep.(1000)), f) |> elem(0) end)
p.("nest 1030", fn -> SVG.parse(wrap.(deep.(1030)), f) end)
p.("cycle", fn -> SVG.parse(wrap.(~s(<g id="a"><use xlink:href="#b"/></g><g id="b"><use xlink:href="#a"/></g>)), f) end)
p.("big number", fn -> SVG.parse(wrap.(~s(<rect width="1e16" height="5"/>)), f) end)
p.("entity markup", fn -> SVG.parse(~s(<?xml version="1.0"?><!DOCTYPE svg [<!ENTITY e "<rect width='5' height='5'/>">]><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10">&e;</svg>), f) end)
p.("max_elements", fn -> SVG.parse(wrap.(String.duplicate("<rect width='1' height='1'/>", 20)), f, max_elements: 10) end)
p.("max_text", fn -> SVG.parse(wrap.("<text>" <> String.duplicate("a", 200) <> "</text>"), f, max_text_per_element: 100) end)
{:ok, doc} = SVG.parse(wrap.("<rect width='5' height='5' fill='red'/>"), f)
p.("cost", fn -> SVG.cost(doc, 10, 10) end)
p.("render", fn -> {:ok, b} = SVG.render(doc, 10, 10); byte_size(b) end)
{:ok, far} = SVG.parse(wrap.("<rect x='40000' width='5' height='5'/>"), f)
p.("out of range", fn -> SVG.render(far, 10, 10) end)
