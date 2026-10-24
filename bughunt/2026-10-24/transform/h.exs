defmodule H do
  import Plug.Test

  def opts(body, ct \\ "image/png") do
    [
      allow_unsigned: true,
      sources: [
        path: [
          adapter: ImagePipe.SourceTest.RootHTTPAdapter,
          match: :path,
          options: [
            root_url: "http://origin.test",
            req_options: [plug: {ImagePipe.Test.BodyOrigin, {body, ct}}]
          ]
        ]
      ]
    ]
  end

  def request(path, opts) do
    :get |> conn(path) |> ImagePipe.Plug.call(ImagePipe.Plug.init(opts))
  end

  def decoded(%Plug.Conn{status: 200} = conn),
    do: {:ok, Image.open!(conn.resp_body, access: :random, fail_on: :error)}

  def decoded(conn), do: {:error, conn.status, conn.resp_body}

  def noise(w, h) do
    {:ok, img} = Vix.Vips.Operation.gaussnoise(w, h, mean: 128.0, sigma: 60.0)
    {:ok, r} = Vix.Vips.Operation.gaussnoise(w, h, mean: 128.0, sigma: 60.0)
    {:ok, g} = Vix.Vips.Operation.gaussnoise(w, h, mean: 128.0, sigma: 60.0)
    {:ok, j} = Vix.Vips.Operation.bandjoin([img, r, g])
    {:ok, j} = Vix.Vips.Operation.cast(j, :VIPS_FORMAT_UCHAR)
    {:ok, j} = Vix.Vips.Operation.copy(j, interpretation: :VIPS_INTERPRETATION_sRGB)
    j
  end

  # stored image such that autorotate(stored tagged n) == display
  def stored_for(display, n) do
    cands =
      for a <- [0, 90, 180, 270], f <- [false, true] do
        img = if a == 0, do: display, else: Image.rotate!(display, a)
        if f, do: Image.flip!(img, :horizontal), else: img
      end

    Enum.find(cands, fn s ->
      tagged = s |> Image.set_orientation!(n)
      bytes = Image.write!(tagged, :memory, suffix: ".png")
      {:ok, {back, _}} = Image.autorotate(Image.open!(bytes, access: :random))
      same?(back, display)
    end)
  end

  def same?(a, b) do
    Image.width(a) == Image.width(b) and Image.height(a) == Image.height(b) and
      elem(Image.compare(a, b), 1) == 0.0
  end

  def maxdiff(a, b) do
    {:ok, d} = Vix.Vips.Operation.subtract(a, b)
    {:ok, d} = Vix.Vips.Operation.abs(d)
    {:ok, {m, _}} = Vix.Vips.Operation.max(d)
    m
  end
end
