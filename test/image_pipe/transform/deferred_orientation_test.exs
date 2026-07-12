defmodule ImagePipe.Transform.DeferredOrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.{Executor, Materializer, State}
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.PendingOrientation
  alias Vix.Vips.Operation, as: VipsOperation

  # Bare-module detector for the end-to-end ordering gate. Executor.execute/3
  # resolves its `:detector` opt through ImagePipe.Transform.resolve_detector/1,
  # which accepts only a bare module (the {module, opts} form is a Crop-level
  # contract), so the recording pid is carried out-of-band via the test process.
  defmodule RecordingDetector do
    @moduledoc false
    @behaviour ImagePipe.Transform.Detector

    @impl true
    def supported_classes(_), do: ["face"]

    @impl true
    def available?(_), do: true

    @impl true
    def identity(_), do: {__MODULE__, :v1}

    @impl true
    def detect(image, _opts) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        pid when is_pid(pid) -> send(pid, {:detect_dims, Image.width(image), Image.height(image)})
        nil -> :ok
      end

      {:ok, []}
    end
  end

  defp marked(w, h),
    do: Image.Draw.rect!(Image.new!(w, h, color: :white), 0, 0, 4, 4, color: :red)

  defp run(plan, image) do
    {:ok, %State{} = s} = Executor.execute(plan, %State{image: image}, seed_orientation: true)
    # Delivery backstop flush (mirrors processor's materialize_for_delivery).
    {:ok, %State{} = s} = Materializer.materialize(s)
    s.image
  end

  # Orientation-only reference uses the SAME primitives the flush uses — the exact
  # `vips_rot` for the user rotate, not Image.rotate/2's affine resampler (#211).
  defp orientation_only_reference(image, user_rotate, user_flips) do
    {:ok, {img, _}} = Image.autorotate(image)
    img = if user_rotate != 0, do: rot_exact!(img, user_rotate), else: img
    Enum.reduce(user_flips, img, fn axis, acc -> Image.flip!(acc, axis) end)
  end

  defp rot_exact!(img, 90), do: ok(VipsOperation.rot(img, :VIPS_ANGLE_D90))
  defp rot_exact!(img, 180), do: ok(VipsOperation.rot(img, :VIPS_ANGLE_D180))
  defp rot_exact!(img, 270), do: ok(VipsOperation.rot(img, :VIPS_ANGLE_D270))

  defp ok({:ok, img}), do: img

  defp sample_positions(size) do
    last = max(size - 1, 0)
    Enum.uniq([0, div(last, 2), last])
  end

  defp assert_pixels_match(a, b) do
    assert {Image.width(a), Image.height(a)} == {Image.width(b), Image.height(b)}

    for x <- sample_positions(Image.width(a)), y <- sample_positions(Image.height(a)) do
      assert Image.get_pixel!(a, x, y) == Image.get_pixel!(b, x, y), "mismatch at (#{x},#{y})"
    end
  end

  defp plan(ops, auto_rotate?) do
    %Plan{
      source: nil,
      output: nil,
      auto_rotate: auto_rotate?,
      pipelines: [%ImagePipe.Plan.Pipeline{operations: ops}]
    }
  end

  defp build_ops(user_rotate, flips) do
    rotate_op = if user_rotate != 0, do: elem(Operation.rotate(user_rotate), 1)
    flip_ops = Enum.map(flips, &elem(Operation.flip(&1), 1))

    Enum.reject([rotate_op | flip_ops], &is_nil/1)
  end

  test "no-geometry EXIF 1..8 + user rotate/flip: deferred flush matches same-primitive reference" do
    for orientation <- 1..8,
        user_rotate <- [0, 90, 180, 270],
        flips <- [[], [:horizontal], [:vertical]] do
      base = Image.set_orientation!(marked(40, 20), orientation)
      ops = build_ops(user_rotate, flips)
      out = run(plan(ops, true), base)
      assert_pixels_match(out, orientation_only_reference(base, user_rotate, flips))
    end
  end

  # ── Detector-ordering gate ───────────────────────────────────────────────────

  # A content-aware (detect) gravity crop requires materialization, so the
  # deferred-orientation flush must fire BEFORE detection — the detector sees the
  # DISPLAY frame, never the storage frame. A portrait-EXIF source (stored 40×80)
  # displays as 80×40 under EXIF-6; the detector must report {80, 40}.
  test "detect crop runs after the orientation flush (sees the display frame)" do
    :persistent_term.put({RecordingDetector, :pid}, self())

    {:ok, _} =
      Executor.execute(detect_crop_plan(true), %State{image: oriented_decoded(6)},
        seed_orientation: true,
        detector: RecordingDetector
      )

    assert_receive {:detect_dims, 80, 40}
  after
    :persistent_term.erase({RecordingDetector, :pid})
  end

  # Negative control: with auto_rotate disabled the flush is suppressed, so the
  # detector sees the STORAGE frame {40, 80}. This proves the positive assertion
  # is sensitive to the flush rather than passing on any unbound dimensions.
  test "ar:0 suppresses the flush so detect sees the storage frame" do
    :persistent_term.put({RecordingDetector, :pid}, self())

    {:ok, _} =
      Executor.execute(detect_crop_plan(false), %State{image: oriented_decoded(6)},
        seed_orientation: true,
        detector: RecordingDetector
      )

    assert_receive {:detect_dims, 40, 80}
  after
    :persistent_term.erase({RecordingDetector, :pid})
  end

  # The FakeDetector `record_to:` opt (the {module, opts} Crop-level contract):
  # after the flush, the detect crop hands the detector the display frame. This
  # exercises the opt-carrying path the wire/Executor detector option cannot.
  test "FakeDetector record_to reports the post-flush display frame" do
    state =
      %State{
        image: oriented_decoded(6),
        detector: {ImagePipe.Test.FakeDetector, record_to: self()},
        pending_orientation: PendingOrientation.from_exif(6, true)
      }

    {:ok, flushed} = Materializer.flush(state)

    op = %Crop{
      width: {:pixels, 30},
      height: {:pixels, 30},
      crop_from: :gravity,
      gravity: {:detect, {["face"], %{}}}
    }

    {:ok, _} = Crop.execute(op, flushed)
    assert_receive {:detect_dims, 80, 40}
  end

  # Real-detector smoke test: the default detector also runs after the flush, on
  # the display frame. Excluded by default (real inference is not wired locally;
  # see project memory) — the FakeDetector/RecordingDetector tests above are the
  # default-lane ordering gate.
  @tag :image_vision
  test "real default detector runs detection on the post-flush display frame" do
    {:ok, crop} =
      Operation.crop_guided({:px, 30}, {:px, 30}, {:detect, {["face"], %{}}})

    {:ok, %State{image: out}} =
      Executor.execute(plan([crop], true), %State{image: oriented_decoded(6)},
        seed_orientation: true,
        detector: :default
      )

    # The crop runs on the 80×40 display frame, so the 30×30 result is a crop of
    # the rotated content, not the 40×80 storage frame.
    assert {Image.width(out), Image.height(out)} == {30, 30}
  end

  defp oriented_decoded(orientation) do
    40
    |> Image.new!(80, color: :white)
    |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
    |> Image.set_orientation!(orientation)
    |> Image.write!(:memory, suffix: ".jpg")
    |> Image.open!(access: :random, fail_on: :error)
  end

  defp detect_crop_plan(auto_rotate?) do
    {:ok, crop} = Operation.crop_guided({:px, 30}, {:px, 30}, {:detect, {["face"], %{}}})
    plan([crop], auto_rotate?)
  end
end
