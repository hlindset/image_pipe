Code.require_file("h.exs", __DIR__)
dir = "/home/user/image_pipe/image_pipe/test/support/image_pipe/test/sources/"

srcs =
  ~w(alpha.png gray.png gray_alpha.png rgb16.png rgba16.png cmyk.jpg icc_p3.png palette.png small.png exif_6.jpg exif_5.jpg high_freq.webp exif_placement_6.jxl)

ops = System.get_env("OPS", "") |> String.split(";", trim: true)

ops =
  if ops != [] do
    ops
  else
    [
      "blur=3", "sharpen=2", "pixelate=5", "progressive-blur=8,down,0.2,0.8",
      "gray", "bitonal", "monochrome=0.7,ff0000", "duotone=1,000080,ffff00",
      "brightness=40", "contrast=1.5", "saturation=2", "colorize=0.5,ff0000",
      "colorize=0.5,ff0000,keep-alpha", "gradient=0.8,ff0000,down,0.2,0.9",
      "bg=ff000080", "bg=00ff00", "pad=5/bg=ff0000", "w=50/h=50/extend/bg=0000ff80",
      "rotate=33", "rotate=33/bg=ff0000", "trim=auto", "trim=fff,20/trim-symmetry=hv",
      "w=30/h=30/fit=cover/anchor=smart", "crop=50pct,50pct/anchor=smart",
      "w=30/blur=1/sharpen=1/gray/brightness=10", "w=200/enlarge/sharpen=3",
      "gray/colorize=0.5,ff0000", "gray/bg=ff000080", "bitonal/gradient=0.5,00ff00,right,0,1",
      "w=10/-/gray/-/w=20/enlarge/bitonal", "rotate=90/w=20/-/rotate=45/-/pixelate=3",
      "w=1/h=1", "w=1/h=1/fit=cover", "crop=1,1", "w=3/pixelate=2"
    ]
  end

fmts = System.get_env("FMTS", "png,jpeg,webp") |> String.split(",")

for s <- srcs, o <- ops, f <- fmts do
  bytes = File.read!(dir <> s)
  ct = MIME.from_path(s)
  path = "/#{o}/format=#{f}/src/#{s}"

  try do
    conn = H.request(path, H.opts(bytes, ct))

    if conn.status != 200 do
      IO.puts("#{conn.status} #{path}: #{String.replace(conn.resp_body, "\n", " | ") |> String.slice(0, 400)}")
    end
  rescue
    e -> IO.puts("RAISE #{path}: #{Exception.message(e) |> String.slice(0, 300)}")
  catch
    k, r -> IO.puts("CATCH #{path}: #{inspect({k, r}) |> String.slice(0, 300)}")
  end
end

IO.puts("done")
