import Plug.Test
[file | pipes] = System.argv()
dir = Path.dirname(Path.expand(file)); name = Path.basename(file)
config = ImagePipe.Plug.init(allow_unsigned: true,
  svg: [],
  sources: [path: [adapter: ImagePipe.Source.File, match: :path, options: [root: dir, root_id: "fz"]]])
for p <- pipes do
  p = if p == "-", do: "", else: p
  t0 = System.monotonic_time(:millisecond)
  res = try do
    c = conn(:get, "/" <> p <> "src/" <> URI.encode(name)) |> ImagePipe.Plug.call(config)
    info = if c.status==200 do
      {:ok, img} = Image.from_binary(c.resp_body); {w,h,b}=Image.shape(img)
      px = fn x,y -> case Image.get_pixel(img,x,y) do {:ok,v}->Enum.map(v,&round/1); e->inspect e end end
      "#{w}x#{h}x#{b} p=#{inspect px.(0,0)}"
    else String.slice(inspect(c.resp_body),0,120) end
    "[#{p}] #{c.status} #{byte_size(c.resp_body)}B #{info}"
  catch k,r -> "[#{p}] RAISE #{inspect k} #{String.slice(inspect(r),0,160)}" end
  IO.puts("#{res} #{System.monotonic_time(:millisecond)-t0}ms")
end
