defmodule ImagePipe.Dialect.Imgproxy.OrientationMatrixTest do
  @moduledoc """
  The orientation-invariance matrix for the imgproxy dialect — the #146
  regression net, ported from `test/image_pipe/dialect/native/orientation_matrix_test.exs`.

  **Closes probe gap G1 — the auto-rotate-OFF arm is exercised end-to-end for the
  first time.** The native dialect has no `orient=` option (EXIF auto-rotate is a
  hardcoded policy), so its matrix could only pin the ABSENCE of an escape hatch
  and defer the OFF arm to core unit tests. imgproxy has the real option (`ar:0`),
  so every cell below runs under BOTH auto-rotate arms through the full wire path.

  EXIF {1, 6, 8} × {region-style crop, cover + focal result crop, plain resize} ×
  auto-rotate {on, off}, asserting per arm:

  1. **Semantic-intent invariance (`ar:1`)** — the dialect's decision about which
     operations to run, and of what KIND, does not branch on storage orientation.
     Captured via `Pipeline`'s test-only `:chain` recorder seam, injected into the
     config after `init/1` and driven through the real `Dialect.Imgproxy.call/2`.
     As in native, the captured items are `NeutralResolver`-RESOLVED executable
     ops, and CORE legitimately storage-compensates their NUMERIC fields under a
     quarter turn (and appends a terminal `Flush{}`), so exact struct equality is
     the WRONG invariant. The assertion is the Flush-stripped op-KIND sequence
     (module + crop-source kind + gravity kind), which belongs to the dialect layer.

  2. **Storage-frame invariance (`ar:0`)** — with auto-rotate off there IS no
     display-frame remap, so the twin oracle does not apply (the display twin
     legitimately differs). The invariant instead is that the EXIF tag is
     IGNORED: an EXIF-k source must produce the same dims and pixels as an
     identically-stored EXIF-1 source. Everything follows the storage frame.

  3. **Pixel invariance (`ar:1`)** — wire-level responses for the twin/oriented
     pair are pixel-close (`PixelCompare`, native's bound: exact dims +
     `fraction_over(…, 40) < 0.05`).

  4. **Shrink correctness** — decode shrink is computed against STORAGE axes while
     planning used DISPLAY axes.

  `ar:0` is separately proven to be HONORED rather than a silently-ignored no-op
  (`describe "auto-rotate OFF is honored (probe gap G1)"`): under a quarter turn it
  must produce demonstrably different dims from `ar:1`.
  """

  # Real fetch/decode through a Plug-backed origin per case — keep it serial,
  # mirroring the native matrix.
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush

  # ── the matrix: {label, imgproxy processing-option segment} ──────────────
  #
  # Every op's target window is sized/positioned to land on non-flat content in
  # `fixture_base/0` (quadrant seams + the two white stripes), so a genuine
  # storage/display-frame mixup shows up as a real pixel divergence rather than a
  # false pass inside a flat region.
  @matrix [
    {"c:100:200:nowe:10:20 (region-style crop)", "c:100:200:nowe:10:20"},
    {"rs:fill:150:100/g:fp:0.75:0.25 (cover + focal result crop)",
     "rs:fill:150:100/g:fp:0.75:0.25"},
    {"rs:fit:160:0 (plain resize)", "rs:fit:160:0"}
  ]

  @orientations [1, 6, 8]

  # ── fixture content (same construction as the native matrix) ────────────
  #
  # 320×240 STORAGE-frame canvas: four 160×120 quadrants (distinct colors) plus
  # two 20px-wide white stripes crossing the frame — thick enough that JPEG
  # block-ringing near the seams stays local, while every matrix op's target
  # window still crosses at least one seam or stripe.
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

  # ── wire helpers ────────────────────────────────────────────────────────

  defp config_for(origin, extra \\ []) do
    ImagePipe.Plug.init(
      dialect: Imgproxy,
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ]
    )
    |> Keyword.merge(extra)
  end

  # `ar:` is explicit on every path: the matrix pins both arms, so neither should
  # ride on the config default (which is auto-rotate ON).
  defp path(opts_segment, ar), do: "/unsafe/#{opts_segment}/ar:#{ar}/f:png/plain/images/x.jpg"

  defp get(path, config), do: conn(:get, path) |> ImagePipe.Plug.call(config)

  defp decoded_image(%Plug.Conn{} = conn),
    do: Image.open!(conn.resp_body, access: :random, fail_on: :error)

  defp get_image!(path, origin, label) do
    conn = get(path, config_for(origin))
    assert conn.status == 200, "#{label}: expected 200, got #{conn.status}"
    decoded_image(conn)
  end

  defp dims(%Plug.Conn{} = conn), do: PixelCompare.dims(decoded_image(conn))

  # ── chain recorder seam ─────────────────────────────────────────────────
  #
  # `Pipeline.run/4` reads `:chain` from the opts it is handed, and `call/2`
  # threads the whole config down to it (`pipeline_opts/4` -> `build_ctx/1`), so
  # injecting the recorder after `init/1` records the real request's ops. The
  # pipeline body runs inside the producer process; `pid` is captured here, so the
  # messages still land in this test process.
  # Records both the ops batch and the dims of the image the chain was entered
  # with — the latter is what the shrink assertion reads (the first entry is the
  # freshly loaded, pre-flush, storage-frame image).
  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops})
      send(pid, {:entry_dims, {Image.width(state.image), Image.height(state.image)}})
      Chain.execute(state, ops, opts)
    end
  end

  defp record_ops(path, origin) do
    pid = self()
    conn = get(path, config_for(origin, chain: recording_chain(pid)))
    {conn, drain_ops([])}
  end

  defp drain_ops(acc) do
    receive do
      {:ops, ops} -> drain_ops([ops | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp drain_entry_dims(acc) do
    receive do
      {:entry_dims, dims} -> drain_entry_dims([dims | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── op-kind projection (same rationale as the native matrix) ────────────

  defp op_kind(%Crop{crop_from: crop_from, gravity: gravity}),
    do: {Crop, crop_from_kind(crop_from), gravity_kind(gravity)}

  defp op_kind(%mod{}), do: {mod, nil, nil}

  defp crop_from_kind(:gravity), do: :gravity
  defp crop_from_kind(%{}), do: :region

  defp gravity_kind(nil), do: nil
  defp gravity_kind(:smart), do: :smart
  defp gravity_kind({:anchor, _, _}), do: :anchor
  defp gravity_kind({:fp, _, _}), do: :fp

  defp op_kind_sequence(ops_batches) do
    ops_batches
    |> List.flatten()
    |> Enum.reject(&match?(%Flush{}, &1))
    |> Enum.map(&op_kind/1)
  end

  # ── 1. semantic-intent invariance (auto-rotate ON) ──────────────────────

  describe "semantic-intent invariance (ar:1)" do
    for orientation <- @orientations, {label, segment} <- @matrix do
      test "EXIF #{orientation}: #{label} emits the same op-kind sequence for twin vs oriented-frame source" do
        orientation = unquote(orientation)
        segment = unquote(segment)
        label = unquote(label)
        request_path = path(segment, 1)
        base_png = fixture_base_png()

        {twin_conn, twin_ops} =
          record_ops(request_path, {Orientation1TwinOrigin, {base_png, orientation}})

        {oriented_conn, oriented_ops} =
          record_ops(request_path, {OrientedFrameOrigin, {base_png, orientation}})

        assert twin_conn.status == 200
        assert oriented_conn.status == 200

        # Anti-vacuity guard: if the `:chain` seam ever stops reaching the recorder,
        # both sides collapse to `[]` and the equality below passes while proving
        # nothing. Every cell in this matrix emits at least one non-Flush op.
        refute Enum.empty?(op_kind_sequence(twin_ops)),
               "EXIF #{orientation} #{label}: recorded no ops — the :chain recorder seam is " <>
                 "not reaching Pipeline.run/4, so this cell's comparison is vacuous"

        assert op_kind_sequence(oriented_ops) == op_kind_sequence(twin_ops),
               "EXIF #{orientation} #{label}: op-kind sequence diverges between the twin " <>
                 "(display-native) and oriented (deferred-rotation) sources — " <>
                 "twin: #{inspect(twin_ops)}, oriented: #{inspect(oriented_ops)}"
      end
    end
  end

  # ── 2. pixel invariance, wire-level twin oracle (auto-rotate ON) ────────

  describe "pixel invariance (ar:1, wire-level twin oracle)" do
    for orientation <- @orientations, {label, segment} <- @matrix do
      test "EXIF #{orientation}: #{label} produces pixel-close wire output for twin vs oriented source" do
        orientation = unquote(orientation)
        segment = unquote(segment)
        label = unquote(label)
        request_path = path(segment, 1)
        base_png = fixture_base_png()
        cell = "EXIF #{orientation} #{label}"

        oriented_img =
          get_image!(request_path, {OrientedFrameOrigin, {base_png, orientation}}, cell)

        twin_img =
          get_image!(request_path, {Orientation1TwinOrigin, {base_png, orientation}}, cell)

        assert PixelCompare.same_dims?(oriented_img, twin_img),
               "#{cell}: dims #{inspect(PixelCompare.dims(oriented_img))} != twin " <>
                 "#{inspect(PixelCompare.dims(twin_img))}"

        # The oriented leg round-trips through the origin's JPEG storage encode; the
        # twin is lossless PNG throughout. A generous per-sample threshold (40 of 255
        # levels) absorbs JPEG block-ringing near the fixture's seams/stripe edges;
        # the OUTLIER FRACTION is bounded tightly (5%) because a real storage/display
        # frame mixup misplaces the whole content window, not just a thin seam.
        fraction = PixelCompare.fraction_over(oriented_img, twin_img, 40)

        assert fraction < 0.05,
               "#{cell}: #{Float.round(fraction * 100, 2)}% of samples diverge by >40 " <>
                 "levels — placement/orientation mismatch, not compression noise"
      end
    end
  end

  # ── 3. storage-frame invariance (auto-rotate OFF) — the G1 arm ──────────

  describe "storage-frame invariance (ar:0, the arm native cannot express)" do
    for orientation <- @orientations, {label, segment} <- @matrix do
      test "EXIF #{orientation}: #{label} ignores the EXIF tag and follows the storage frame" do
        orientation = unquote(orientation)
        segment = unquote(segment)
        label = unquote(label)
        request_path = path(segment, 0)
        base_png = fixture_base_png()
        cell = "EXIF #{orientation} #{label} (ar:0)"

        # Same STORAGE pixels, differing only in the EXIF tag. With auto-rotate off
        # the tag must have no effect at all, so these two must agree.
        tagged_img =
          get_image!(request_path, {OrientedFrameOrigin, {base_png, orientation}}, cell)

        untagged_img = get_image!(request_path, {OrientedFrameOrigin, {base_png, 1}}, cell)

        assert PixelCompare.same_dims?(tagged_img, untagged_img),
               "#{cell}: dims #{inspect(PixelCompare.dims(tagged_img))} != untagged-twin " <>
                 "#{inspect(PixelCompare.dims(untagged_img))} — the EXIF tag changed the " <>
                 "result despite ar:0, so auto-rotate was not actually disabled"

        # Both legs are JPEG-encoded from identical storage pixels (only the EXIF
        # tag differs), so this is a near-exact comparison; the bound matches the
        # ar:1 arm's for consistency.
        fraction = PixelCompare.fraction_over(tagged_img, untagged_img, 40)

        assert fraction < 0.05,
               "#{cell}: #{Float.round(fraction * 100, 2)}% of samples diverge by >40 levels " <>
                 "— the EXIF tag affected pixels despite ar:0"
      end
    end
  end

  # ── ar:0 is honored, not silently ignored (probe gap G1) ────────────────

  describe "auto-rotate OFF is honored (probe gap G1)" do
    # The storage-frame invariance above would catch a silently-ignored ar:0, but
    # only indirectly. This pins the observable directly: for a quarter turn, the
    # two arms MUST disagree, and each must follow its own frame.
    #
    # `fixture_base/0` is 320×240 in storage; EXIF 6/8 are quarter turns, so the
    # DISPLAY frame is 240×320. `rs:fit:160:0` fits width 160:
    #   ar:1 (display 240×320) -> 160×213
    #   ar:0 (storage 320×240) -> 160×120
    for orientation <- [6, 8] do
      test "EXIF #{orientation}: ar:0 follows the storage frame while ar:1 follows the display frame" do
        orientation = unquote(orientation)
        base_png = fixture_base_png()
        config = config_for({OrientedFrameOrigin, {base_png, orientation}})

        on_conn = get(path("rs:fit:160:0", 1), config)
        off_conn = get(path("rs:fit:160:0", 0), config)

        assert on_conn.status == 200
        assert off_conn.status == 200

        assert dims(on_conn) == {160, 213},
               "EXIF #{orientation} ar:1: #{inspect(dims(on_conn))} != {160, 213} (display frame)"

        assert dims(off_conn) == {160, 120},
               "EXIF #{orientation} ar:0: #{inspect(dims(off_conn))} != {160, 120} (storage " <>
                 "frame) — ar:0 was ignored and the source auto-rotated anyway"
      end
    end

    test "EXIF 1: ar:0 and ar:1 agree (no orientation to defer)" do
      base_png = fixture_base_png()
      config = config_for({OrientedFrameOrigin, {base_png, 1}})

      assert dims(get(path("rs:fit:160:0", 1), config)) ==
               dims(get(path("rs:fit:160:0", 0), config))
    end
  end

  # ── 4. shrink correctness ───────────────────────────────────────────────

  describe "shrink correctness (orientation 6 quarter turn)" do
    # A 1600×1200 STORAGE-frame source tagged EXIF-6: DISPLAY dims are 1200×1600.
    # `w:200` targets the DISPLAY width and nothing else. The decode must shrink the
    # STORAGE axes by a factor computed against the axis-SWAPPED comparison (as if
    # storage were display-shaped, 1200×1600) vs that target: 1200/200 = 6.0, capped
    # to a jpeg shrink-on-load of 4, landing the loaded (pre-flush, still
    # storage-orientation) image at 1600/4 × 1200/4 = 400×300. Skipping the axis swap
    # would divide the unswapped storage width instead: 1600/200 = 8.0 -> shrink 8 ->
    # 200×150, a visibly different, wrong, loaded size.
    #
    # The 200 is load-bearing, not arbitrary (the brief's `w:300` does NOT
    # discriminate — verified: it yields the same {400, 300} chain entry, because
    # 4.0 and 6.0 both quantize to a jpeg shrink of 4, so the test would pass with
    # or without the swap).
    test "the real decode shrinks the STORAGE axes consistently with the display-frame plan" do
      base_png =
        Image.write!(Image.new!(1600, 1200, color: [90, 100, 110]), :memory, suffix: ".png")

      pid = self()

      config =
        config_for({OrientedFrameOrigin, {base_png, 6}}, chain: recording_chain(pid))

      conn = get("/unsafe/w:200/f:png/plain/images/x.jpg", config)
      assert conn.status == 200

      # The FIRST chain entry sees the freshly loaded image, before any op and before
      # the orientation flush — i.e. the shrink-on-load result in the storage frame.
      assert [loaded_dims | _] = drain_entry_dims([])

      assert loaded_dims == {400, 300},
             "loaded (pre-flush, storage-frame) dims #{inspect(loaded_dims)} != {400, 300} " <>
               "— the decode shrink was computed against the wrong axis pair"

      # And the request still lands on its display-frame target: 200 wide, aspect
      # preserved against the 1200×1600 display frame.
      assert dims(conn) == {200, 267},
             "final (display-frame) dims #{inspect(dims(conn))} != {200, 267}"
    end
  end
end
