defmodule H do
  @root "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_processing/img"
  def root, do: @root
  def setup do
    mk("s300x300.png", 300, 300)
    mk("s300x200.png", 300, 200)
    mk("s150.png", 150, 150)
    mk("s120x90.png", 120, 90)
    mk("s1200x600.png", 1200, 600)
    mk("s2000x1000.jpg", 2000, 1000)
    mk("s800x600.jpg", 800, 600)
    :ok
  end
  def mk(name, w, h) do
    p = Path.join(@root, name)
    unless File.exists?(p) do
      {:ok, img} = Vix.Vips.Operation.xyz(w, h)
      {:ok, img} = Vix.Vips.Operation.cast(img, :VIPS_FORMAT_UCHAR)
      {:ok, b} = Vix.Vips.Operation.extract_band(img, 0)
      {:ok, img} = Vix.Vips.Operation.bandjoin([img, b])
      {:ok, img} = Vix.Vips.Operation.copy(img, interpretation: :VIPS_INTERPRETATION_sRGB)
      :ok = Vix.Vips.Image.write_to_file(img, p)
    end
  end
  def opts(extra \\ []) do
    ImagePipe.Plug.init(Keyword.merge([allow_unsigned: true,
      sources: [media: [adapter: ImagePipe.Source.File, match: :path, options: [root: @root, root_id: "media"]]]], extra))
  end
  def req(path, extra \\ [], headers \\ []) do
    conn = Plug.Test.conn(:get, path)
    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    conn = ImagePipe.Plug.call(conn, opts(extra))
    conn
  end
  def show(path, extra \\ [], headers \\ []) do
    c = req(path, extra, headers)
    dims = case Image.from_binary(c.resp_body) do
      {:ok, i} -> "#{Image.width(i)}x#{Image.height(i)} bands=#{Image.bands(i)}"
      _ -> inspect(String.slice(c.resp_body || "", 0, 200))
    end
    ct = Plug.Conn.get_resp_header(c, "content-type")
    IO.puts("#{path} -> #{c.status} #{inspect ct} #{dims}")
    c
  end
end
H.setup()
defmodule P do
  def px(path, x, y, extra \\ []) do
    c = H.req(path, extra)
    {:ok, i} = Image.from_binary(c.resp_body)
    {:ok, v} = Image.get_pixel(i, x, y)
    IO.puts("#{path} @#{x},#{y} -> #{c.status} #{Image.width(i)}x#{Image.height(i)} #{inspect v}")
  end
  def hdr(path, extra \\ [], headers \\ []) do
    c = H.req(path, extra, headers)
    IO.puts("#{path} -> #{c.status} #{inspect c.resp_headers}")
    if c.status >= 400, do: IO.puts("   body: #{inspect c.resp_body}")
    c
  end
end
