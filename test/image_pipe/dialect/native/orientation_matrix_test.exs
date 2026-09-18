defmodule ImagePipe.Native.OrientationMatrixTest do
  @moduledoc """
  Native orientation regression coverage for display-frame geometry and
  storage-frame shrink-on-load planning.
  """

  # Real fetch/decode through a Plug-backed origin per case — keep it serial,
  # mirroring pipeline_pixel_test.exs and native_wire_test.exs.
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Decode
  alias ImagePipe.Native
  alias ImagePipe.Native.Parser
  alias ImagePipe.Native.Presets
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  # ── the matrix: {label, native-dialect option segments} ───────────────────
  #
  # Every op's target window is sized/positioned to land on non-flat content
  # in `fixture_base/0` below (quadrant seams + the two white stripes), so a
  # genuine storage/display-frame mixup shows up as a real pixel divergence,
  # not a false pass inside a flat region.

  @matrix [
    {"region=10,20,100,200 (explicit-region crop)", ["region=10,20,100,200"]},
    {"crop=100,80/anchor=top-left (guided crop)", ["crop=100,80", "anchor=top-left"]},
    {"fit=cover/w=150/h=100/focus=0.75,0.25 (cover + focal result crop)",
     ["fit=cover", "w=150", "h=100", "focus=0.75,0.25"]},
    {"plain w=160 resize", ["w=160"]}
  ]

  @orientations [1, 6, 8]

  # ── fixture content ────────────────────────────────────────────────────
  #
  # 320×240 STORAGE-frame canvas: four 160×120 quadrants (distinct colors)
  # plus two 20px-wide white stripes crossing the frame — thick enough that
  # JPEG block-ringing near the seams stays local (unlike a 1px line), while
  # every matrix op's target window still crosses at least one seam or
  # stripe (verified by hand against each op's box below), so pixel
  # invariance is actually exercised, not vacuously true over a flat field.
  defp fixture_base do
    320
    |> Image.new!(240, color: :green)
    |> Image.Draw.rect!(0, 0, 160, 120, color: :red)
    |> Image.Draw.rect!(160, 0, 160, 120, color: :blue)
    |> Image.Draw.rect!(0, 120, 160, 120, color: :yellow)
    |> Image.Draw.rect!(160, 120, 160, 120, color: [200, 0, 200])
    |> Image.Draw.rect!(70, 0, 20, 240, color: :white)
    |> Image.Draw.rect!(0, 50, 320, 20, color: :white)
  end

  defp fixture_base_png, do: Image.write!(fixture_base(), :memory, suffix: ".png")

  # ── parser helpers (mirrors parser_test.exs) ───────────────────────────

  defp seg(raw), do: {raw, {0, byte_size(raw)}}

  defp lexed(segments, source \\ "images/x.jpg"),
    do: %{segments: Enum.map(segments, &seg/1), source: {:src, source, {0, byte_size(source)}}}

  defp parse!(segments) do
    assert {:ok, request} = Parser.parse(lexed(segments), [])
    request
  end

  defp source_opts(origin, extra \\ []) do
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

  # ── wire-level helpers (mirrors native_wire_test.exs) ──────────────────

  defp native_opts(origin) do
    ImagePipe.Plug.init(
      dialect: Native,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ]
    )
  end

  defp get(path, config) do
    conn(:get, path) |> ImagePipe.Plug.call(config)
  end

  defp native_path(segments) do
    "/" <> Enum.join(segments ++ ["format=png"], "/") <> "/src/images/x.jpg"
  end

  defp decoded_image(%Plug.Conn{} = conn),
    do: Image.open!(conn.resp_body, access: :random, fail_on: :error)

  # ── pixel invariance (wire-level) ───────────────────────────────────────

  describe "pixel invariance (wire-level twin oracle)" do
    for orientation <- @orientations, {label, segments} <- @matrix do
      test "EXIF #{orientation}: #{label} produces pixel-close wire output for twin vs oriented source" do
        orientation = unquote(orientation)
        segments = unquote(segments)
        label = unquote(label)
        path = native_path(segments)
        base_png = fixture_base_png()

        oriented_conn = get(path, native_opts({OrientedFrameOrigin, {base_png, orientation}}))
        twin_conn = get(path, native_opts({Orientation1TwinOrigin, {base_png, orientation}}))

        assert oriented_conn.status == 200,
               "EXIF #{orientation} #{label} (oriented leg): #{oriented_conn.status}"

        assert twin_conn.status == 200,
               "EXIF #{orientation} #{label} (twin leg): #{twin_conn.status}"

        oriented_img = decoded_image(oriented_conn)
        twin_img = decoded_image(twin_conn)

        assert PixelCompare.same_dims?(oriented_img, twin_img),
               "EXIF #{orientation} #{label}: dims #{inspect(PixelCompare.dims(oriented_img))} " <>
                 "!= twin #{inspect(PixelCompare.dims(twin_img))}"

        # The oriented leg round-trips through the origin's JPEG storage
        # encode (`OrientedFrameOrigin`); the twin is lossless PNG throughout.
        # A generous per-sample threshold (40 of 255 levels) absorbs JPEG
        # block-ringing near the fixture's quadrant seams/stripe edges; the
        # OUTLIER FRACTION is bounded tightly (5%) because a real
        # storage/display-frame mixup misplaces the whole content window, not
        # just a thin seam, and would blow well past this fraction.
        fraction = PixelCompare.fraction_over(oriented_img, twin_img, 40)

        assert fraction < 0.05,
               "EXIF #{orientation} #{label}: #{Float.round(fraction * 100, 2)}% of samples " <>
                 "diverge by >40 levels — placement/orientation mismatch, not compression noise"
      end
    end
  end

  # ── shrink correctness ──────────────────────────────────────────────────

  describe "shrink correctness (orientation 6 quarter turn)" do
    # A 1600x1200 STORAGE-frame source tagged EXIF-6 (quarter turn): DISPLAY
    # dims are 1200x1600. `w=200` targets the DISPLAY width and nothing else, so
    # the preflight's target is {200, nil} — the assertion below. The real decode
    # must then shrink the STORAGE axes (1600x1200) by a factor computed against
    # the axis-SWAPPED comparison (as if storage were display-shaped, 1200x1600)
    # vs that target: 1200/200 = 6.0 -> a jpeg shrink-on-load of 4, landing the
    # loaded (pre-flush, still-storage-orientation) image at 1600/4 x 1200/4 =
    # 400x300. Skipping the axis swap would divide the unswapped storage width
    # instead: 1600/200 = 8.0 -> shrink 8 -> 200x150, a visibly different, wrong,
    # loaded size.
    #
    # The 200 is load-bearing, not arbitrary: a single-axis target makes the swap
    # decide which source axis is divided, so the two candidates must straddle a
    # jpeg power-of-2 shrink boundary to be told apart. `w=300` gives 4.0 vs 5.33
    # — both quantize to shrink 4, and the test would pass either way.
    defp exif_six_source do
      {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
      base_png = Image.write!(base, :memory, suffix: ".png")
      {OrientedFrameOrigin, {base_png, 6}}
    end

    test "decode_request/2 leaves the untargeted axis nil rather than synthesizing one" do
      # `w=200` targets one axis; the partner stays `nil` so the planner takes
      # the targeted axis's ratio alone. A synthesized aspect axis would bind
      # `ratio_from_targets/4`'s `min/2` tighter and shrink less.
      #
      # Frame-independent by construction — with no synthesized axis there is no
      # geometry this could resolve against, so this pins the no-synthesis rule
      # and nothing about the display frame. That subject is the sibling test
      # below, which discriminates the axis pair through a real decode.
      request = parse!(["w=200"])

      geometry = %SourceGeometry{
        storage_dimensions: {1600, 1200},
        display_dimensions: {1200, 1600},
        pending_orientation: PendingOrientation.from_exif(6, true),
        source_format: :jpeg
      }

      decode_request = Executor.decode_request(request, geometry)

      assert decode_request.resize_target == {200, nil}
    end

    test "the real decode shrinks the STORAGE axes consistently with that display-frame plan" do
      request = parse!(["w=200"])
      opts = source_opts(exif_six_source())

      {:ok, {loaded_w, loaded_h}} =
        Decode.with_image(
          resolved(opts),
          opts,
          &Executor.decode_request(request, &1),
          fn state, _geometry -> {:ok, {Image.width(state.image), Image.height(state.image)}} end
        )

      assert {loaded_w, loaded_h} == {400, 300},
             "loaded (pre-flush) dims #{inspect({loaded_w, loaded_h})} != expected {400, 300} " <>
               "— the decode shrink was computed against the wrong axis pair"
    end
  end

  describe "request orientation policy" do
    test "defaults to auto and accepts explicit none" do
      assert parse!([]).orient == :auto
      assert parse!(["orient=auto"]).orient == :auto
      assert parse!(["orient=none"]).orient == :none
    end

    test "orient is request-scoped and rejects duplicates across groups" do
      assert {:error, {:invalid_request, diagnostics}} =
               Parser.parse(lexed(["orient=auto", "then", "orient=none"]), [])

      assert Enum.any?(diagnostics, &(&1.reason == :duplicate_option))
    end

    test "the default preset can select orient=none" do
      assert {:ok, presets} = Presets.validate_config(%{"default" => "orient=none"})
      assert {:ok, request} = Parser.parse(lexed([]), presets: presets)
      assert request.orient == :none
    end
  end
end
