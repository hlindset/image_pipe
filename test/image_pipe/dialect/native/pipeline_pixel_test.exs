defmodule ImagePipe.Dialect.Native.PipelinePixelTest do
  # Real fetch/decode through a Plug-backed origin per case — keep it serial,
  # mirroring test/image_pipe/decode_test.exs.
  use ExUnit.Case, async: false

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Dialect.Native.Request
  alias ImagePipe.Dialect.Native.Request.Group
  alias ImagePipe.Dialect.Native.Request.Output
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  # ── Origin plugs ─────────────────────────────────────────────────────────

  defmodule LandscapeOrigin do
    @moduledoc false
    # A plain 1600x1200 landscape JPEG.
    def call(conn, _opts) do
      {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
      body = Image.write!(base, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule OddOrigin do
    @moduledoc false
    # A source whose dims don't divide evenly into common resize targets, to
    # exercise the cover result-crop's ±1-prone measured-dims path.
    def call(conn, _opts) do
      {:ok, base} = Image.new(777, 555, color: [10, 20, 30])
      body = Image.write!(base, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule TrimSourceOrigin do
    @moduledoc false
    # An 800x800 white canvas with a 400x400 red block centered — lossless
    # PNG so `trim=fff` (threshold 0, exact match) sees exact white pixels
    # with no lossy-compression noise at the block edge.
    def call(conn, _opts) do
      {:ok, canvas} = Image.new(800, 800, color: [255, 255, 255])
      {:ok, block} = Image.new(400, 400, color: [220, 20, 60])
      {:ok, composed} = Image.compose(canvas, block, x: 200, y: 200)
      body = Image.write!(composed, :memory, suffix: ".png")

      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  # A 1600x1200 (storage) landscape source tagged EXIF-6 (quarter turn), so
  # `auto_rotate?: true` makes the pipeline autorotate it to a 1200x1600
  # (display) portrait — the storage/display mismatch that lets a pct
  # crop/region resolved against the wrong frame be caught pixel-side.
  defp exif_six_landscape_origin do
    {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
    base_png = Image.write!(base, :memory, suffix: ".png")
    {OrientedFrameOrigin, {base_png, 6}}
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp source_opts(origin, extra) do
    Source.validate_config!(
      Keyword.merge(
        [
          sources: [
            path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
          ],
          max_body_bytes: 10_000_000,
          max_input_pixels: 40_000_000,
          auto_rotate?: true
        ],
        extra
      )
    )
  end

  defp resolved(opts) do
    {:ok, resolved} = Source.resolve(%SourcePath{segments: ["images", "x.jpg"]}, opts, [])
    resolved
  end

  defp req(groups, output \\ %Output{}) do
    %Request{groups: groups, output: output, source: "test"}
  end

  defp group(fields), do: struct!(Group, fields)

  defp run_native(origin, %Request{} = request, extra \\ []) do
    opts = source_opts(origin, extra)

    Decode.with_image(
      resolved(opts),
      opts,
      &Pipeline.decode_request(request, &1),
      fn state, geometry -> Pipeline.run(state, geometry, request, opts) end
    )
  end

  # ── output dimensions per fit mode ────────────────────────────────────────

  describe "output dimensions per fit mode (1600x1200 landscape source, 300x400 portrait box)" do
    test "contain: scales to fit within the box, preserving aspect" do
      request = req([group(%{resize: %{w: 300, h: 400, fit: :contain, enlarge: false}})])

      assert {:ok, %State{image: image}} = run_native(LandscapeOrigin, request)
      assert {Image.width(image), Image.height(image)} == {300, 225}
    end

    test "cover: fills the box exactly, cropping overflow" do
      request = req([group(%{resize: %{w: 300, h: 400, fit: :cover, enlarge: false}})])

      assert {:ok, %State{image: image}} = run_native(LandscapeOrigin, request)
      assert {Image.width(image), Image.height(image)} == {300, 400}
    end

    test "cover-down: behaves like cover when the source is larger than the box" do
      request = req([group(%{resize: %{w: 300, h: 400, fit: :cover_down, enlarge: false}})])

      assert {:ok, %State{image: image}} = run_native(LandscapeOrigin, request)
      assert {Image.width(image), Image.height(image)} == {300, 400}
    end

    test "stretch: forces the exact box regardless of aspect" do
      request = req([group(%{resize: %{w: 300, h: 400, fit: :stretch, enlarge: false}})])

      assert {:ok, %State{image: image}} = run_native(LandscapeOrigin, request)
      assert {Image.width(image), Image.height(image)} == {300, 400}
    end

    test "auto: opposite orientation buckets (landscape source, portrait box) resolve to fit" do
      request = req([group(%{resize: %{w: 300, h: 400, fit: :auto, enlarge: false}})])

      assert {:ok, %State{image: image}} = run_native(LandscapeOrigin, request)
      assert {Image.width(image), Image.height(image)} == {300, 225}
    end
  end

  # ── cover result-crop exactness at ±1-prone sizes ─────────────────────────

  test "cover result-crop lands on the exact requested box on a non-round source" do
    request = req([group(%{resize: %{w: 333, h: 222, fit: :cover, enlarge: false}})])

    assert {:ok, %State{image: image}} = run_native(OddOrigin, request)
    assert {Image.width(image), Image.height(image)} == {333, 222}
  end

  # ── the cheap-trim contract: trim in group 2 runs on group 1's output ────

  test "w=400/then/trim=fff trims the POST-resize image, not the source" do
    request =
      req([
        group(%{resize: %{w: 400, h: :auto, fit: :contain, enlarge: false}}),
        group(%{trim: {{255, 255, 255}, 0}})
      ])

    assert {:ok, %State{image: image}} = run_native(TrimSourceOrigin, request)
    width = Image.width(image)
    height = Image.height(image)

    # If trim had run against the 800x800 source instead, the surviving red
    # block would be ~400x400, not ~200x200 — this pins the group ordering.
    # A small tolerance absorbs the resize kernel's antialiasing at the
    # red/white edge (exact-match trim, threshold 0, keeps the blurred rim).
    assert_in_delta width, 200, 10
    assert_in_delta height, 200, 10
    assert width == height
  end

  # ── pct crop/region resolve against the DISPLAY frame, not storage ───────
  #
  # EXIF-6 source: storage 1600x1200, display 1200x1600 (quarter turn). A pct
  # length must resolve against the CURRENT DISPLAY dims (1200x1600), not the
  # storage dims the shape carries pre-orientation-flush — else the box comes
  # out transposed and mis-sized (Task 14 review Critical).

  test "guided pct crop resolves against display dims under a quarter-turn EXIF source" do
    request =
      req([
        group(%{
          crop: {{:pct, 50}, {:pct, 50}},
          guide: {:anchor, :center}
        })
      ])

    assert {:ok, %State{image: image}} = run_native(exif_six_landscape_origin(), request)
    # 50% of the 1200x1600 DISPLAY frame => 600x800. Pre-fix, this resolved
    # 50% of the 1600x1200 STORAGE frame instead (800x600, a wrong box that
    # is also transposed relative to the correct display-frame answer).
    assert {Image.width(image), Image.height(image)} == {600, 800}
  end

  test "pct region resolves against display dims under a quarter-turn EXIF source" do
    request =
      req([
        group(%{region: {{:pct, 0}, {:pct, 0}, {:pct, 25}, {:pct, 50}}})
      ])

    assert {:ok, %State{image: image}} = run_native(exif_six_landscape_origin(), request)

    # 25%/50% of the 1200x1600 DISPLAY frame => 300x800. Resolved against the
    # 1600x1200 STORAGE frame instead (the pre-fix bug), this comes out
    # 400x600 — a different, wrong, box (this pct pair is NOT axis-symmetric,
    # so it distinguishes the two frames where the 50/50 crop case above
    # cannot).
    assert {Image.width(image), Image.height(image)} == {300, 800}
  end

  test "px crop stays correct (display-frame pixels pass through unchanged) under the same EXIF-6 source" do
    request =
      req([
        group(%{
          crop: {{:px, 600}, {:px, 800}},
          guide: {:anchor, :center}
        })
      ])

    assert {:ok, %State{image: image}} = run_native(exif_six_landscape_origin(), request)
    assert {Image.width(image), Image.height(image)} == {600, 800}
  end

  # ── intra-group pct basis: resolved against the group-INPUT display dims,
  # before this group's own trim runs (documented, pinned choice — see
  # `group_operations/2`'s moduledoc note) ─────────────────────────────────

  test "a pct crop in a group that also trims resolves against the group's PRE-trim display dims" do
    request =
      req([
        group(%{
          trim: {{255, 255, 255}, 0},
          crop: {{:pct, 50}, {:pct, 50}},
          guide: {:anchor, :center}
        })
      ])

    assert {:ok, %State{image: image}} = run_native(TrimSourceOrigin, request)

    # TrimSourceOrigin is an 800x800 white canvas with a centered 400x400
    # block. A post-trim pct basis would resolve 50% of ~400x400 => ~200x200;
    # the group-input (pre-trim) basis this dialect uses resolves 50% of the
    # untouched 800x800 source => 400x400. Small tolerance for the trim
    # threshold-0 antialiasing rim (mirrors the cheap-trim contract test
    # above).
    assert_in_delta Image.width(image), 400, 10
    assert_in_delta Image.height(image), 400, 10
  end

  # ── decode_request/2 preflight values ─────────────────────────────────────

  describe "decode_request/2 preflight" do
    defp geometry(display_dims) do
      %SourceGeometry{
        storage_dimensions: display_dims,
        display_dimensions: display_dims,
        pending_orientation: %ImagePipe.Transform.PendingOrientation{},
        source_format: :jpeg
      }
    end

    test "a plain resize sets resize_target with :auto resolved against display dims" do
      request = req([group(%{resize: %{w: 400, h: :auto, fit: :contain, enlarge: false}})])
      decode_request = Pipeline.decode_request(request, geometry({1600, 1200}))

      assert decode_request.resize_target == {400, 300}
      assert decode_request.crop_extent == nil
      assert decode_request.trim? == false
      assert decode_request.terminal_reduction == nil
    end

    test "a crop before the resize sets crop_extent from the FIRST group's crop" do
      request =
        req([
          group(%{
            crop: {{:px, 600}, {:px, 400}},
            guide: {:anchor, :center},
            resize: %{w: 300, h: :auto, fit: :contain, enlarge: false}
          })
        ])

      decode_request = Pipeline.decode_request(request, geometry({1600, 1200}))

      assert decode_request.resize_target == {300, 200}
      assert decode_request.crop_extent == {600, 400}
    end

    test "a trim-only first group sets trim?: true and no resize_target" do
      request = req([group(%{trim: :auto})])
      decode_request = Pipeline.decode_request(request, geometry({1600, 1200}))

      assert decode_request.trim? == true
      assert decode_request.resize_target == nil
    end

    test "a trim in a LATER group does not set trim? (only the first group governs)" do
      request =
        req([
          group(%{resize: %{w: 400, h: :auto, fit: :contain, enlarge: false}}),
          group(%{trim: :auto})
        ])

      decode_request = Pipeline.decode_request(request, geometry({1600, 1200}))

      assert decode_request.trim? == false
      assert decode_request.resize_target == {400, 300}
    end

    test "output=blurhash sets the terminal reduction regardless of groups" do
      request = req([group(%{})], %Output{terminal: :blurhash})
      decode_request = Pipeline.decode_request(request, geometry({1600, 1200}))

      assert decode_request.terminal_reduction == {32, 32}
    end
  end
end
