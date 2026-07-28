defmodule ImagePipe.Parser.IIIF.OpenSeadragonSimTest do
  @moduledoc """
  Replicates OpenSeadragon's IIIF v3 getTileUrl algorithm (src/iiiftilesource.js)
  to drive a full pan/zoom tile traversal against a live ImagePipe IIIF endpoint,
  then verifies the served tiles. The OSD replica is the STIMULUS generator; an
  independent 2D-gradient expectation (NOT the ImagePipe planner / resize path)
  is the ORACLE.

  Note on fidelity: the replica computes `level_w = ceil(W*scale)`. The real OSD,
  once it adopts our `sizes` as `levelSizes`, reads the level dims from `sizes`
  instead — but the two coincide at every level for this fixture, so the replica
  is behaviorally faithful here.
  """
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Dialect.IIIF.Resolver.Static, as: StaticResolver
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @w 1024
  @h 768

  # --- 2D-gradient origin: pixel(x,y) ~ [255*x/(w-1), 0, 255*y/(h-1)] ----------
  # A served tile from source region (xr,yr,wr,hr) decodes so its corners track
  # the region's source corners — independent of any resize kernel.
  defmodule GradientOrigin do
    alias Vix.Vips.Image, as: VipsImage
    alias Vix.Vips.Operation, as: Op

    def init(opts), do: opts

    def call(conn, _opts) do
      w = 1024
      h = 768
      ramp = Op.xyz!(w, h)
      scaled = Op.linear!(ramp, [255.0 / (w - 1), 255.0 / (h - 1)], [0.0, 0.0])
      g = Op.black!(w, h)
      rgb = Op.bandjoin!([scaled[0], g, scaled[1]])
      uchar = Op.cast!(rgb, :VIPS_FORMAT_UCHAR)
      {:ok, body} = VipsImage.write_to_buffer(uchar, ".png")

      conn |> put_resp_content_type("image/png") |> send_resp(200, body)
    end
  end

  defp opts do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: {StaticResolver, map: %{"grad" => %SourcePath{segments: ["grad.png"]}}}],
      sources: [
        path:
          {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: GradientOrigin]}
      ]
    ]
  end

  defp call_iiif(path) do
    initialized = ImagePipe.Plug.init(opts())
    conn = :get |> conn(path) |> Map.put(:script_name, ["iiif"])
    ImagePipe.Plug.call(conn, initialized)
  end

  # --- OSD getTileUrl replica (per iiiftilesource.js, v3) ----------------------
  # Each tile -> a uniform map: %{region, size, w, h, src: {xr,yr,wr,hr}} where
  # (w,h) is the served output size and `src` is the SOURCE region the tile covers
  # (full image for the single-tile branch). Uniform maps avoid fragile
  # positional tuples.
  defp osd_tiles(info) do
    [%{"width" => tile_w} = tile] = info["tiles"]
    tile_h = Map.get(tile, "height", tile_w)
    factors = tile["scaleFactors"]
    max_level = round(:math.log2(Enum.max(factors)))

    Enum.flat_map(0..max_level, &level_requests(&1, max_level, tile_w, tile_h))
  end

  defp level_requests(level, max_level, tile_w, tile_h) do
    scale = :math.pow(0.5, max_level - level)
    level_w = ceil(@w * scale)
    level_h = ceil(@h * scale)

    if level_w < tile_w and level_h < tile_h do
      # Single-tile branch: whole (downscaled) image fits one tile -> region full.
      # The `max` arm is unreachable for sources LARGER than the tile (level_w<tile_w
      # implies level_w<@w); it mirrors OSD's guard for sub-tile sources.
      size = if level_w == @w and level_h == @h, do: "max", else: "#{level_w},#{level_h}"
      [%{region: "full", size: size, w: level_w, h: level_h, src: {0, 0, @w, @h}}]
    else
      iiif_tile_w = round(tile_w / scale)
      iiif_tile_h = round(tile_h / scale)
      cols = ceil(level_w / tile_w)
      rows = ceil(level_h / tile_h)

      ctx = %{
        tile_w: tile_w,
        tile_h: tile_h,
        iiif_tile_w: iiif_tile_w,
        iiif_tile_h: iiif_tile_h,
        level_w: level_w,
        level_h: level_h
      }

      for x <- 0..(cols - 1), y <- 0..(rows - 1), do: tile_request(x, y, ctx)
    end
  end

  defp tile_request(x, y, ctx) do
    tile_x = x * ctx.iiif_tile_w
    tile_y = y * ctx.iiif_tile_h
    region_w = min(ctx.iiif_tile_w, @w - tile_x)
    region_h = min(ctx.iiif_tile_h, @h - tile_y)

    region =
      if x == 0 and y == 0 and region_w == @w and region_h == @h,
        do: "full",
        else: "#{tile_x},#{tile_y},#{region_w},#{region_h}"

    size_w = min(ctx.tile_w, ctx.level_w - x * ctx.tile_w)
    size_h = min(ctx.tile_h, ctx.level_h - y * ctx.tile_h)
    size = if size_w == @w and size_h == @h, do: "max", else: "#{size_w},#{size_h}"

    %{
      region: region,
      size: size,
      w: size_w,
      h: size_h,
      src: {tile_x, tile_y, region_w, region_h}
    }
  end

  setup do
    info = JSON.decode!(call_iiif("/grad/info.json").resp_body)
    {:ok, info: info}
  end

  # Single gate loop: fire each tile ONCE; assert status + served dims + the
  # independent pixel oracle (TL, center, BR). Covers both OSD branches and the
  # full pan/zoom traversal. For 1024x768/512 (factors [1,2,4,8], maxLevel=3):
  #   level 0 (sf8): single-tile full / 128,96
  #   level 1 (sf4): single-tile full / 256,192
  #   level 2 (sf2): TILED, 1x1 grid, region=full / 512,384  (full region, downscaled)
  #   level 3 (sf1): TILED, 2x2 grid -> (0,0) interior, (1,0) right edge,
  #                  (0,1) bottom edge, (1,1) bottom-right corner (512,256 clamps)
  test "OSD traversal: every tile served 200 with correct dims + source geometry",
       %{info: info} do
    for %{region: region, size: size, w: sw, h: sh, src: {xr, yr, wr, hr}} <- osd_tiles(info) do
      conn = call_iiif("/grad/#{region}/#{size}/0/default.png")
      assert conn.status == 200, "#{region}/#{size} -> #{conn.status}"

      img = Image.open!(conn.resp_body, access: :random, fail_on: :error)

      assert {Image.width(img), Image.height(img)} == {sw, sh},
             "#{region}/#{size}: served #{Image.width(img)}x#{Image.height(img)}, expected #{sw}x#{sh}"

      # Oracle: expected gradient values at TL / center / BR, derived from the
      # SOURCE region geometry (red tracks x, blue tracks y). No resize involved.
      [tl_r, _, tl_b | _] = Image.get_pixel!(img, 0, 0)
      [c_r, _, c_b | _] = Image.get_pixel!(img, div(sw, 2), div(sh, 2))
      [br_r, _, br_b | _] = Image.get_pixel!(img, sw - 1, sh - 1)

      assert_close(tl_r, 255 * xr / (@w - 1), "tl red @ #{region}")
      assert_close(tl_b, 255 * yr / (@h - 1), "tl blue @ #{region}")
      assert_close(c_r, 255 * (xr + wr / 2) / (@w - 1), "center red @ #{region}")
      assert_close(c_b, 255 * (yr + hr / 2) / (@h - 1), "center blue @ #{region}")
      assert_close(br_r, 255 * (xr + wr - 1) / (@w - 1), "br red @ #{region}")
      assert_close(br_b, 255 * (yr + hr - 1) / (@h - 1), "br blue @ #{region}")

      # Edge/corner tiles must be clamped, not the full tile size.
      if wr < 512, do: assert(sw < 512)
      if hr < 512, do: assert(sh < 512)
    end
  end

  test "single-tile branch yields region=full with a downscaled w,h size", %{info: info} do
    # level 0 (sf=8) -> 128x96 single tile, region full (no HTTP call needed).
    assert Enum.any?(osd_tiles(info), &match?(%{region: "full", size: "128,96"}, &1))
  end

  # Tolerance is calibrated to the measured worst-case resize/encode blur across
  # every served tile in the traversal (~1.4 units). ±6 comfortably passes that
  # blur while bounding the region-origin blind spot: the gradient slope is
  # 255/(@w-1) ≈ 0.249 red units/source-px in x and 255/(@h-1) ≈ 0.333 blue
  # units/source-px in y, so ±6 only tolerates a region-origin error of ~24
  # source px in x / ~18 source px in y. That fails on a sub-tile region bug, on
  # any whole-tile (~128px) shift, and on a missed edge clamp.
  defp assert_close(actual, expected, label) do
    assert abs(actual - expected) <= 6,
           "#{label}: got #{actual}, expected ~#{Float.round(expected * 1.0, 1)}"
  end
end
