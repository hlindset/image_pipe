defmodule ImagePipe.OrderedSpikeTest do
  # Real fetch/decode through a Plug-backed origin per case — keep it serial,
  # mirroring test/image_pipe/decode_test.exs and
  # test/image_pipe/dialect/native/pipeline_pixel_test.exs.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias ImagePipe.Decode
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.OrderedSpike.Pipeline
  alias ImagePipe.Test.Orientation1TwinOrigin
  alias ImagePipe.Test.OrientedFrameOrigin
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State

  # ── Origin plugs ─────────────────────────────────────────────────────────

  defmodule LandscapeOrigin do
    @moduledoc false
    # A plain 1600x1200 landscape JPEG (orientation 1 — storage == display).
    def call(conn, _opts) do
      {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
      body = Image.write!(base, :memory, suffix: ".jpg")

      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defmodule StaticBodyOrigin do
    @moduledoc false
    # Serves fixed, pre-encoded bytes captured at plug-config time — lets the
    # property test encode ONE fixture up front and reuse it across every
    # `check all` iteration (only the command list varies per run).
    def init(body), do: body

    def call(conn, body) do
      conn
      |> Plug.Conn.put_resp_content_type("image/webp")
      |> Plug.Conn.send_resp(200, body)
    end
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

  # Runs the spike pipeline end to end: decode preflight (via
  # `Pipeline.decode_request/2`) → `Pipeline.run/3`. Returns whatever
  # `Pipeline.run/3` returns (`{:ok, state, dims_history}` or `{:error, _}`),
  # passed straight through `Decode.with_image/4`.
  defp run_ordered(origin, commands, extra_opts) do
    opts = source_opts(origin, extra_opts)

    Decode.with_image(
      resolved(opts),
      opts,
      &Pipeline.decode_request(commands, &1),
      fn state, _geometry -> Pipeline.run(state, commands) end
    )
  end

  # Same bracket, but with a caller-supplied `decode_request_fun` — lets a
  # test force a specific (or no-op) decode preflight regardless of what
  # `Pipeline.preflight/2` would compute, to build a no-shrink baseline.
  defp run_ordered_with_request(origin, commands, decode_request_fun, extra_opts) do
    opts = source_opts(origin, extra_opts)

    Decode.with_image(resolved(opts), opts, decode_request_fun, fn state, _geometry ->
      Pipeline.run(state, commands)
    end)
  end

  defp no_shrink_request(%SourceGeometry{}), do: %DecodePlanner.Request{}

  # ── Part A: interpreter correctness ─────────────────────────────────────

  describe "run/3 — dims after each command" do
    test "each command's dims chain from the previous command's realized output" do
      commands = [{:resize_w, 500}, {:crop_rel, 0.5, 0.5}, {:resize_w, 200}]

      assert {:ok, %State{image: image}, dims_history} =
               run_ordered(LandscapeOrigin, commands, [])

      assert length(dims_history) == length(commands)
      assert List.last(dims_history) == {Image.width(image), Image.height(image)}

      [{w1, h1}, {w2, h2}, {w3, h3}] = dims_history

      # resize_w(500), mode :fit, height :auto — preserves the 1600x1200
      # source aspect ratio exactly.
      assert w1 == 500
      assert_in_delta h1, 375, 1

      # crop_rel(0.5, 0.5) — half of whatever resize_w(500) just produced.
      assert w2 == max(1, round(w1 * 0.5))
      assert h2 == max(1, round(h1 * 0.5))

      # resize_w(200) from the crop's own output — no upstream dependency.
      assert w3 == 200
      assert_in_delta h3, round(200 * h2 / w2), 1
    end

    test "dims after each command are identical regardless of storage orientation" do
      {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
      base_png = Image.write!(base, :memory, suffix: ".png")

      commands = [{:resize_w, 480}, {:crop_rel, 0.6, 0.75}, {:resize_h, 150}]

      # OrientedFrameOrigin: storage 1600x1200 tagged EXIF-6 (quarter turn) —
      # display dims 1200x1600 after auto-rotate.
      assert {:ok, %State{}, quarter_turn_dims} =
               run_ordered({OrientedFrameOrigin, {base_png, 6}}, commands, [])

      # Orientation1TwinOrigin: the SAME displayed pixels, pre-rotated and
      # served untagged (orientation 1 — storage == display already).
      assert {:ok, %State{}, identity_dims} =
               run_ordered({Orientation1TwinOrigin, {base_png, 6}}, commands, [])

      assert quarter_turn_dims == identity_dims
    end
  end

  # ── Part B: preflight/2 — the decode-bound answer ───────────────────────

  describe "preflight/2 — propagation rules" do
    test "an absolute op alone requires exactly its own target, freeing the other axis" do
      assert Pipeline.preflight([{:resize_w, 600}], {2000, 1500}) == %{
               minimum_loaded_width: 600,
               minimum_loaded_height: 1
             }

      assert Pipeline.preflight([{:resize_h, 300}], {2000, 1500}) == %{
               minimum_loaded_width: 1,
               minimum_loaded_height: 300
             }
    end

    test "a relative op before an absolute op scales the requirement up (worked example from the brief)" do
      commands = [{:resize_w, 500}, {:crop_rel, 0.5, 0.5}, {:resize_w, 200}]

      # The crop takes half; to still deliver >=200 into the final resize_w,
      # its OWN input must be >=400 — but the FIRST resize_w(500) is an
      # absolute op that resets the requirement outright to 500 regardless
      # (500 > 400, so it — not the propagated 400 — is what decode must
      # honor; anything less than 500 would make resize_w(500) itself clamp
      # under the interpreter's `enlarge: false` default).
      assert Pipeline.preflight(commands, {2000, 1500}) == %{
               minimum_loaded_width: 500,
               minimum_loaded_height: 1
             }
    end

    test "a purely relative command list (no absolute anchor) has no safe bound" do
      assert Pipeline.preflight([{:crop_rel, 0.5, 0.5}], {2000, 1500}) == :no_shrink

      assert Pipeline.preflight([{:crop_rel, 0.5, 1.0}, {:crop_rel, 0.4, 0.4}], {2000, 1500}) ==
               :no_shrink
    end

    test "a concrete requirement is clamped to the header extent, never demanding more than the source has" do
      # crop_rel(0.1) before resize_w(500) propagates to 500/0.1 = 5000 —
      # far beyond the 2000px header width; the floor must not exceed it.
      assert Pipeline.preflight([{:crop_rel, 0.1, 1.0}, {:resize_w, 500}], {2000, 1500}) == %{
               minimum_loaded_width: 2000,
               minimum_loaded_height: 1
             }
    end
  end

  describe "preflight/2 — the documented no-bound case" do
    test "a leading :trim collapses the whole bound to :no_shrink, and the cost delta is measured against the boundable tail alone" do
      header = {2000, 1500}
      tail = [{:resize_w, 200}]

      assert Pipeline.preflight([:trim | tail], header) == :no_shrink

      assert Pipeline.preflight(tail, header) == %{
               minimum_loaded_width: 200,
               minimum_loaded_height: 1
             }

      # The measured cost of the trim's uncertainty: with no leading trim,
      # decode could safely shrink the width axis down to 200px; leading
      # with :trim forces the FULL header width (2000px) instead — a 1800px
      # delta on that axis alone, purely from :trim's presence.
      {header_w, _header_h} = header
      assert header_w - 200 == 1800
    end
  end

  # ── required_extent — the decode-efficiency answer ──────────────────────
  #
  # `DecodePlanner.open_options_for/5` treats `required_extent` as a PURE CAP
  # on an ALREADY-desired shrink (`compute_load_shrink_for_request/3` never
  # reads it — only `cap_to_required_extent/4` does, and only AFTER a shrink
  # ratio has already been computed from `trim?`/`resize_target`/
  # `terminal_reduction`). With none of those set — exactly
  # `Pipeline.decode_request/2`'s shape, per the brief's instruction to carry
  # the preflight's answer via `required_extent` alone, NOT `resize_target`
  # — the pre-cap shrink is always `1.0`, and `min(1.0, floor_ratio)` stays
  # `1.0` for any floor `floor_ratio >= 1.0` (i.e. any floor that does not
  # exceed the header, which `preflight/2` guarantees by clamping). So
  # `required_extent` alone produces ZERO decode-time effect — not because
  # the preflight's floor is loose, but because `required_extent` (Task 11)
  # was built as a safety net paired with a driving field, not as a
  # standalone driver. This is the concrete form of "the ordered spike needs
  # its own field" — record it for the Task 21 report.
  describe "required_extent — the decode-efficiency answer" do
    test "required_extent ALONE never drives shrink — it only caps an already-desired shrink" do
      floor_only = %DecodePlanner.Request{required_extent: {200, 1}}

      assert DecodePlanner.open_options_for(floor_only, :jpeg, {1600, 1200}, false, false) ==
               [access: :sequential, fail_on: :error]
    end

    test "the SAME floor value, paired with a driving field, DOES achieve the shrink required_extent alone could not" do
      # `resize_target` is a stand-in driver for this ONE test only — never
      # used by `Pipeline.decode_request/2` (see the moduledoc note above:
      # the brief rules it out because its output-box-target semantics
      # misstate a floor). This test isolates the other half of the claim:
      # the floor NUMBER preflight/2 computes is sound (not too loose), so
      # the gap demonstrated above is purely about `required_extent`'s
      # wiring, not about the preflight's arithmetic.
      driven = %DecodePlanner.Request{resize_target: {200, 1}, required_extent: {200, 1}}

      assert [access: :sequential, fail_on: :error, shrink: n] =
               DecodePlanner.open_options_for(driven, :jpeg, {1600, 1200}, false, false)

      assert n in [2, 4, 8]
    end

    test "end to end: Pipeline.decode_request/2 (required_extent only) yields zero measured decode-time savings, even for a tight, boundable command list" do
      assert {:ok, %State{} = trimmed, _dims} =
               run_ordered(LandscapeOrigin, [:trim, {:resize_w, 200}], [])

      refute trimmed.decode_shrink

      assert {:ok, %State{} = boundable, _dims} =
               run_ordered(LandscapeOrigin, [{:resize_w, 200}], [])

      # A tight (200px), correctly-computed floor — SHIPPED via
      # `Pipeline.decode_request/2`, `required_extent` only — still produces
      # NO measured decode-time benefit, confirming the wiring gap above
      # end to end, not just at the `DecodePlanner` unit level.
      refute boundable.decode_shrink
    end
  end

  # ── Preflight soundness property ────────────────────────────────────────
  #
  # LIMITATION (stated here and in the Task 21 report): this property pins
  # GEOMETRY soundness up to a SMALL, EMPIRICALLY-CALIBRATED rounding
  # tolerance (±2px), not exact equality. The codebase already documents a
  # ±1px tolerance for core's own single-resize shrink-on-load path
  # (`test/image_pipe/shrink_on_load_property_test.exs`: "the contract is
  # NOT 'output equals the full-decode result' — the residual resize scales
  # by a fractional factor, so even the full-decode path can land ±1px
  # off"). The ordered dialect's version of this is STRICTLY WORSE, because
  # it compounds: core resolves every op's geometry against a SINGLE
  # original extent up front, but THIS interpreter measures the LIVE
  # (already-rounded) image at every step (`run/3`'s whole design). A
  # non-binding axis's decode-time size is whatever the decoder's single
  # uniform `scale`/`shrink` factor rounds it to (independent of the
  # binding axis's own rounding), and each SUBSEQUENT relative command
  # (`:crop_rel`) re-rounds again from that already-rounded input — so
  # drift compounds per relative stage instead of being bounded once. An
  # offline calibration sweep (3000 random 1-4 command lists, same
  # generator shape as below, see the Task 21 report) found max drift 2px
  # (2/3000 cases), 1px (191/3000), 0px otherwise — ±2px is the empirically
  # safe bound for THIS generator's depth (<=4 commands), not a proven
  # fixed constant; a deeper ordered pipeline could compound further. This
  # property also does NOT assert perceptual/pixel-content equivalence:
  # two decodes at different resolutions landing on matching (or ±2px)
  # final dims can still differ in actual pixel content (a more
  # aggressively shrunk-then-resized path resamples from fewer source
  # pixels) — accepted for this synthetic, geometry-only command set
  # (resize/crop only; `:trim` is deliberately excluded from the generator
  # and covered separately above, since its OWN output geometry is
  # content-dependent and not what this property is measuring).
  #
  # Uses `driven_shrink_request/2` (below), NOT `Pipeline.decode_request/2`:
  # the "required_extent — the decode-efficiency answer" tests above show
  # `required_extent` alone never actually shrinks anything under the
  # current `DecodePlanner` wiring, which would make a property comparing
  # "shrink run" vs "no-shrink run" vacuously true (both runs would decode
  # at full resolution). Pairing the SAME floor with `resize_target` as a
  # driver exercises a REAL shrink, so this property validates what it
  # claims to: that `preflight/2`'s arithmetic never picks a shrink
  # aggressive enough to meaningfully change final geometry.
  describe "preflight soundness property" do
    property "final dims under the preflight-derived shrink match the no-shrink run's final dims within a small, empirically-calibrated rounding tolerance" do
      {:ok, base} = Image.new(1600, 1200, color: [90, 100, 110])
      body = Image.write!(base, :memory, suffix: ".webp")
      origin = {StaticBodyOrigin, body}

      check all(commands <- commands_gen(), max_runs: 30) do
        assert {:ok, %State{}, shrink_dims} =
                 run_ordered_with_request(
                   origin,
                   commands,
                   &driven_shrink_request(commands, &1),
                   []
                 )

        assert {:ok, %State{}, full_dims} =
                 run_ordered_with_request(origin, commands, &no_shrink_request/1, [])

        {shrink_w, shrink_h} = List.last(shrink_dims)
        {full_w, full_h} = List.last(full_dims)
        max_drift = 2

        assert abs(shrink_w - full_w) <= max_drift and abs(shrink_h - full_h) <= max_drift,
               "command list #{inspect(commands)} diverged beyond ±#{max_drift}px: " <>
                 "shrink-preflight final #{inspect({shrink_w, shrink_h})} vs " <>
                 "no-shrink final #{inspect({full_w, full_h})}"
      end
    end
  end

  # Wires `preflight/2`'s floor through `resize_target` (a field that DOES
  # drive `load_shrink`) IN ADDITION TO `required_extent` — a test-only
  # stand-in for the driving field `Pipeline.decode_request/2` deliberately
  # does not use (see the moduledoc note there and the "required_extent —
  # the decode-efficiency answer" tests above). This validates the
  # preflight's ARITHMETIC independent of that wiring gap.
  defp driven_shrink_request(commands, %SourceGeometry{display_dimensions: dims}) do
    required =
      case Pipeline.preflight(commands, dims) do
        :no_shrink -> dims
        %{minimum_loaded_width: w, minimum_loaded_height: h} -> {w, h}
      end

    %DecodePlanner.Request{resize_target: required, required_extent: required}
  end

  defp commands_gen do
    StreamData.list_of(command_gen(), min_length: 1, max_length: 4)
  end

  defp command_gen do
    StreamData.one_of([
      StreamData.tuple({StreamData.constant(:resize_w), StreamData.integer(60..1400)}),
      StreamData.tuple({StreamData.constant(:resize_h), StreamData.integer(60..1100)}),
      StreamData.tuple(
        {StreamData.constant(:crop_rel), StreamData.float(min: 0.3, max: 1.0),
         StreamData.float(min: 0.3, max: 1.0)}
      )
    ])
  end
end
