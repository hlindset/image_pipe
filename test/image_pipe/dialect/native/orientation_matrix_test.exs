defmodule ImagePipe.Dialect.Native.OrientationMatrixTest do
  @moduledoc """
  Task 19: the orientation-invariance matrix — the probe's #146 regression
  net for the native URL dialect.

  The native dialect plans ALL geometry (crop/region/resize/focal gravity)
  against the DISPLAY frame (`ImagePipe.Dialect.Native.Pipeline.group_operations/2`);
  only core (`NeutralResolver`/`Lowering`/the orientation flush) performs the
  storage-frame compensation once the deferred `pending_orientation` is
  eventually flushed. This matrix exercises EXIF orientation {1, 6, 8} ×
  {explicit-region crop, guided top-left crop, cover+focal result crop, plain
  resize} and asserts three invariants per cell:

  1. **Semantic-intent invariance** — the dialect's DECISION about which
     operations to run, and of what KIND, does not branch on storage
     orientation. Captured via the same `chain:` recorder seam
     `pipeline_test.exs` uses (`run/4`'s test-only chain override), comparing
     an EXIF-oriented source (`ImagePipe.Test.OrientedFrameOrigin`) against
     its orientation-1 twin (`ImagePipe.Test.Orientation1TwinOrigin`, same
     displayed pixels, tag stripped) — see `describe "semantic-intent
     invariance"`. The captured items are `NeutralResolver`-RESOLVED
     executable ops (`ImagePipe.Transform.Operation.*`), not the dialect's
     pre-resolve `Plan.Operation` — there is no test-only seam to intercept
     the latter without touching frozen `Pipeline`/`transform/*` source, so
     this compares the CLOSEST observable surface. Because CORE's own job
     under a quarter turn is to storage-compensate those executable ops'
     NUMERIC fields (width/height/mode/gravity anchor can legitimately swap
     or change value — proven empirically: see the Task 19 report) and to
     append a terminal `Flush{}`, an EXACT struct-equality assertion is the
     WRONG invariant — it fails even on provably-correct geometry (assertion
     2 below passes for every one of these same cells). The assertion here is
     therefore the invariant that genuinely belongs to the DIALECT layer: the
     Flush-stripped op-KIND sequence (module + crop-source kind + gravity
     kind, deliberately excluding axis-dependent numeric fields) is identical
     — proving `group_operations/2` (which only reads `display_dims` + group
     config, both storage-orientation-invariant) never itself branches on
     storage orientation; only core's downstream numeric resolution and the
     orientation-driven `Flush` differ.
  2. **Pixel invariance** — wire-level `Dialect.Native.call/2` responses for
     the twin/oriented pair are pixel-close (reusing
     `ImagePipe.Test.Differential.PixelCompare`) — see
     `describe "pixel invariance (wire-level twin oracle)"`.
  3. **Shrink correctness** — decode shrink is computed against STORAGE axes
     (the quarter-turn swap) while planning used DISPLAY axes: the loaded
     (pre-flush) image comes out shrunk in the storage frame, not transposed
     or mis-shrunk against the wrong axis pair — see
     `describe "shrink correctness (orientation 6 quarter turn)"`.

  **Documented subset limitation.** The probe's native dialect has no
  `orient=` option — EXIF auto-rotate is a FIXED policy
  (`ImagePipe.Dialect.Native.@auto_rotate?` is hardcoded `true`, per
  `ImagePipe.Decode.with_image/4`'s "the EXIF policy is the CALLER's choice"
  contract). The exit criterion's "auto-rotate OFF" arm is therefore NOT
  exercisable end-to-end through this dialect; it is validated only at the
  CORE level by `ImagePipe.Transform.SourceGeometry.planning_frame/2` unit
  tests (Task 12). `describe "auto-rotate is a fixed policy"` below pins that
  there is no URL-grammar escape hatch, so this omission is a proven
  boundary, not a silent gap.
  """

  # Real fetch/decode through a Plug-backed origin per case — keep it serial,
  # mirroring pipeline_pixel_test.exs and native_wire_test.exs.
  use ExUnit.Case, async: false

  import Plug.Test

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Native
  alias ImagePipe.Dialect.Native.Parser
  alias ImagePipe.Dialect.Native.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

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

  # ── direct Pipeline driving (mirrors pipeline_pixel_test.exs's run_native/3,
  # extended with pipeline_test.exs's recording chain) ────────────────────

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

  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops})
      Chain.execute(state, ops, opts)
    end
  end

  # Runs the request against `origin` through the REAL decode + pipeline
  # (genuine fetch/decode/transform, not a hand-built State), returning both
  # the pipeline result and the ordered list of executable-op batches the
  # chain recorder observed.
  defp run_with_ops(origin, request) do
    opts = source_opts(origin)
    pid = self()

    result =
      Decode.with_image(
        resolved(opts),
        opts,
        &Pipeline.decode_request(request, &1),
        fn state, geometry ->
          Pipeline.run(state, geometry, request, Keyword.put(opts, :chain, recording_chain(pid)))
        end
      )

    {result, drain_ops([])}
  end

  defp drain_ops(acc) do
    receive do
      {:ops, ops} -> drain_ops([ops | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── wire-level helpers (mirrors native_wire_test.exs) ──────────────────

  defp native_opts(origin) do
    Native.init(
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
      ]
    )
  end

  defp get(path, config) do
    conn(:get, path) |> Native.call(config)
  end

  defp native_path(segments) do
    "/" <> Enum.join(segments ++ ["format=png"], "/") <> "/src/images/x.jpg"
  end

  defp decoded_image(%Plug.Conn{} = conn),
    do: Image.open!(conn.resp_body, access: :random, fail_on: :error)

  # ── 1. semantic-intent invariance ───────────────────────────────────────
  #
  # A Flush-stripped op-KIND sequence: module + crop-source kind (:region vs
  # :gravity) + gravity kind (nil/:smart/:anchor/:fp) — deliberately excluding
  # axis-dependent numeric fields (width/height/mode/exact anchor/fp values),
  # which CORE (not the dialect) legitimately resolves differently per
  # storage orientation. See the moduledoc note above for why exact struct
  # equality is the wrong invariant here.

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

  describe "semantic-intent invariance (Task 14 op-emission surface)" do
    for orientation <- @orientations, {label, segments} <- @matrix do
      test "EXIF #{orientation}: #{label} emits the same op-kind sequence for twin vs oriented-frame source" do
        orientation = unquote(orientation)
        segments = unquote(segments)
        label = unquote(label)
        request = parse!(segments)
        base_png = fixture_base_png()

        {twin_result, twin_ops} =
          run_with_ops({Orientation1TwinOrigin, {base_png, orientation}}, request)

        {oriented_result, oriented_ops} =
          run_with_ops({OrientedFrameOrigin, {base_png, orientation}}, request)

        assert {:ok, %State{}} = twin_result
        assert {:ok, %State{}} = oriented_result

        assert op_kind_sequence(oriented_ops) == op_kind_sequence(twin_ops),
               "EXIF #{orientation} #{label}: op-kind sequence diverges between the twin " <>
                 "(display-native) and oriented (deferred-rotation) sources — " <>
                 "twin: #{inspect(twin_ops)}, oriented: #{inspect(oriented_ops)}"
      end
    end
  end

  # ── 2. pixel invariance (wire-level) ────────────────────────────────────

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

  # ── 3. shrink correctness ───────────────────────────────────────────────

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

    test "decode_request/2 plans resize_target against the DISPLAY frame" do
      request = parse!(["w=200"])

      geometry = %SourceGeometry{
        storage_dimensions: {1600, 1200},
        display_dimensions: {1200, 1600},
        pending_orientation: PendingOrientation.from_exif(6, true),
        source_format: :jpeg
      }

      decode_request = Pipeline.decode_request(request, geometry)

      assert decode_request.resize_target == {200, nil}
    end

    test "the real decode shrinks the STORAGE axes consistently with that display-frame plan" do
      request = parse!(["w=200"])
      opts = source_opts(exif_six_source())

      {:ok, {loaded_w, loaded_h}} =
        Decode.with_image(
          resolved(opts),
          opts,
          &Pipeline.decode_request(request, &1),
          fn state, _geometry -> {:ok, {Image.width(state.image), Image.height(state.image)}} end
        )

      assert {loaded_w, loaded_h} == {400, 300},
             "loaded (pre-flush) dims #{inspect({loaded_w, loaded_h})} != expected {400, 300} " <>
               "— the decode shrink was computed against the wrong axis pair"
    end
  end

  # ── auto-rotate is a fixed policy (documented subset limitation) ───────

  describe "auto-rotate is a fixed policy" do
    test "the native dialect's URL grammar has no orient= escape hatch" do
      assert {:error, {:invalid_request, _diagnostics}} = Parser.parse(lexed(["orient=none"]), [])
    end
  end
end
