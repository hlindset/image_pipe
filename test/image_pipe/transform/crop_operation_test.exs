defmodule ImagePipe.Transform.CropOperationTest do
  use ExUnit.Case, async: true

  import ImagePipe.Test.Telemetry, only: [attach_own_event_handlers: 2]

  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.State

  defp state(width, height) do
    {:ok, image} = Image.new(width, height, color: :white)
    %State{image: image}
  end

  defp dimensions(%State{image: image}), do: {Image.width(image), Image.height(image)}

  test "reduce shrinks the long axis to match ratio (default)" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 100} == dimensions(result)
  end

  test "enlarge grows the short axis to match ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {200, 200} == dimensions(result)
  end

  test "enlarge clamps to image bounds keeping ratio" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 1},
      enlarge: true
    }

    # image only 150 tall; enlarged 200x200 must shrink to fit -> 150x150
    {:ok, result} = Crop.execute(op, state(400, 150))
    assert {150, 150} == dimensions(result)
  end

  test "nil aspect_ratio leaves the crop unchanged" do
    op = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 200},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: nil,
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 400))
    assert {100, 200} == dimensions(result)
  end

  test "fractional crop size on an odd dimension rounds half away from zero" do
    # 401 * 0.5 = 200.5 — a `.5` tie. imgproxy's CalcCropSize rounds crop sizes
    # half-away-from-zero (imath.Scale -> math.Round) -> 201, not ties-to-even 200.
    op = %Crop{
      width: {:scale, 0.5},
      height: :auto,
      crop_from: :gravity,
      gravity: {:anchor, :center, :center}
    }

    {:ok, result} = Crop.execute(op, state(401, 300))
    assert {201, 300} == dimensions(result)
  end

  test "aspect-ratio correction rounds the adjusted crop size half away from zero" do
    # height 201 × ratio 1:2 → 201 * 0.5 = 100.5, a `.5` tie. imgproxy resolves
    # aspect-ratio-corrected crop SIZES with imath.Scale (half-away, like CalcCropSize
    # and the OSS ExtendAspectRatio) -> 101, not ties-to-even 100. (#318 follow-up;
    # car is imgproxy Pro, so this is convention-based, not bake-verifiable.)
    op = %Crop{
      width: {:pixels, 300},
      height: {:pixels, 201},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 1, 2},
      enlarge: false
    }

    {:ok, result} = Crop.execute(op, state(400, 300))
    assert {101, 201} == dimensions(result)
  end

  test "aspect-ratio bounds clamp rounds the scaled crop size half away from zero" do
    # corrected 300×200 clamped to a 300×103 image: scale 103/200 = 0.515, so the
    # width 300 * 0.515 = 154.5 — a `.5` tie. The shrink-to-fit is also a SIZE, so it
    # rounds half-away (155), not ties-to-even (154).
    op = %Crop{
      width: {:pixels, 300},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center},
      aspect_ratio: {:ratio, 3, 2},
      enlarge: true
    }

    {:ok, result} = Crop.execute(op, state(300, 103))
    assert {155, 103} == dimensions(result)
  end

  describe "smart gravity" do
    test "smart crop produces the requested dimensions" do
      image = Image.open!("priv/static/images/woman.jpg")
      state = %State{image: image}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: :smart
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100
      assert Image.height(out) == 100
    end

    test "smart crop differs from a centered crop on an off-center subject" do
      image = Image.open!("priv/static/images/woman.jpg")
      state = %State{image: image}

      base = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity
      }

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      {:ok, %{image: center}} =
        Crop.execute(%{base | gravity: {:anchor, :center, :center}}, state)

      refute Image.write!(smart, :memory, suffix: ".png") ==
               Image.write!(center, :memory, suffix: ".png")
    end
  end

  describe "detect gravity" do
    setup do
      {:ok, image} = Image.new(400, 400, color: :white)
      {:ok, image: image}
    end

    test "anchors on the area-weighted centroid of detected boxes" do
      # A uniform image makes a detect-anchored crop byte-identical to the
      # attention fallback, so use a real photo and a corner face box: the
      # detected crop must diverge from the pure-attention (:smart) crop.
      image = Image.open!("priv/static/images/woman.jpg")

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 30, 30}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100 and Image.height(out) == 100

      {:ok, %{image: attention}} =
        Crop.execute(%{op | gravity: :smart}, %State{image: image})

      png = fn img -> Image.write!(img, :memory, suffix: ".png") end
      refute png.(out) == png.(attention)
    end

    test "no detections falls back to attention" do
      # On a real photo, the no-detection fallback must be byte-identical to a
      # pure-attention (:smart) crop, proving detection is bypassed cleanly.
      image = Image.open!("priv/static/images/woman.jpg")

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 100

      {:ok, %{image: attention}} =
        Crop.execute(%{op | gravity: :smart}, %State{image: image})

      assert Image.write!(out, :memory, suffix: ".png") ==
               Image.write!(attention, :memory, suffix: ".png")
    end

    test "out-of-image box is dropped, falls back to attention", %{image: image} do
      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {-50, -50, 5, 5}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "detector error falls back to attention (graceful)", %{image: image} do
      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:error, :boom}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "nil detector falls back to attention", %{image: image} do
      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "malformed detector return (bad box shape) falls back to attention", %{image: image} do
      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: :nonsense}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      assert {:ok, %{image: _}} = Crop.execute(op, state)
    end

    test "the detect span carries the resolved weights", %{image: image} do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 30, 30}}]}]}
      }

      {:ok, _} =
        Crop.execute(
          %Crop{
            width: {:pixels, 50},
            height: {:pixels, 50},
            crop_from: :gravity,
            gravity: {:detect, {:all, %{"face" => 3.0}}}
          },
          state
        )

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, %{duration: _}, metadata}
      assert metadata.classes == :all
      assert metadata.weights == %{"face" => 3.0}

      :telemetry.detach(ref)
    end

    test "detection emits a [:image_pipe, :transform, :detect] span with safe metadata", %{
      image: image
    } do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {10, 10, 20, 20}}]}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, %{duration: _}, metadata}
      refute Map.has_key?(metadata, :source_url)
      assert metadata.classes == ["face"]
      assert metadata.regions == 1
      assert metadata.result == :detected

      :telemetry.detach(ref)
    end

    test "no-detection fallback reports result: :no_regions on the detect span", %{image: image} do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, _m, metadata}
      assert metadata.regions == 0
      assert metadata.result == :no_regions

      :telemetry.detach(ref)
    end

    test "detector error reports result: :error on the detect span", %{image: image} do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :stop]])

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:error, :boom}]}
      }

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :stop], ^ref, _m, metadata}
      assert metadata.result == :error

      :telemetry.detach(ref)
    end

    test "nil detector emits a [:transform, :detect, :skipped] one-shot, not a span", %{
      image: image
    } do
      ref =
        attach_own_event_handlers(self(), [
          [:image_pipe, :transform, :detect, :skipped],
          [:image_pipe, :transform, :detect, :stop]
        ])

      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:detect, {["face"], %{}}}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :skipped], ^ref, _measurements, metadata}
      assert metadata.classes == ["face"]
      assert metadata.result == :no_detector
      # No span fires: nothing ran.
      refute_received {[:image_pipe, :transform, :detect, :stop], ^ref, _, _}

      :telemetry.detach(ref)
    end
  end

  describe "face-assist gravity" do
    setup do
      image = Image.open!("priv/static/images/woman.jpg")
      {:ok, image: image}
    end

    test "face_assist blends attention with the face centroid (differs from pure attention)", %{
      image: image
    } do
      # Fake a face in one corner; the blended crop must differ from pure :smart attention.
      fake =
        {ImagePipe.Test.FakeDetector,
         [result: {:ok, [%{label: "face", score: 0.9, box: {5, 5, 8, 8}}]}]}

      state = %State{image: image, detector: fake}

      base = %Crop{width: {:pixels, 200}, height: {:pixels, 200}, crop_from: :gravity}

      {:ok, %{image: assist}} =
        Crop.execute(%{base | gravity: {:smart, :face_assist}}, state)

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      png = fn img -> Image.write!(img, :memory, suffix: ".png") end
      refute png.(assist) == png.(smart)
    end

    test "face_assist with no faces falls back to pure attention", %{image: image} do
      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      base = %Crop{width: {:pixels, 200}, height: {:pixels, 200}, crop_from: :gravity}

      {:ok, %{image: assist}} =
        Crop.execute(%{base | gravity: {:smart, :face_assist}}, state)

      {:ok, %{image: smart}} = Crop.execute(%{base | gravity: :smart}, state)

      assert Image.write!(assist, :memory, suffix: ".png") ==
               Image.write!(smart, :memory, suffix: ".png")
    end

    test "face_assist with nil detector falls back to pure attention", %{image: image} do
      state = %State{image: image, detector: nil}

      op = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:smart, :face_assist}
      }

      assert {:ok, %{image: out}} = Crop.execute(op, state)
      assert Image.width(out) == 200
    end

    test "face_assist emits a [:transform, :detect, :blend] one-shot with the skew", %{
      image: image
    } do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :blend]])

      state = %State{
        image: image,
        detector:
          {ImagePipe.Test.FakeDetector,
           [result: {:ok, [%{label: "face", score: 0.9, box: {5, 5, 8, 8}}]}]}
      }

      op = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:smart, :face_assist}
      }

      {:ok, _} = Crop.execute(op, state)

      assert_receive {[:image_pipe, :transform, :detect, :blend], ^ref, _measurements, meta}
      assert {ax, ay} = meta.attention
      assert {fx, fy} = meta.face
      assert {bx, by} = meta.blended
      assert meta.weight == 0.7
      # Blended point is the weighted mix actually used: 0.7*face + 0.3*attention.
      assert_in_delta bx, 0.7 * fx + 0.3 * ax, 1.0e-9
      assert_in_delta by, 0.7 * fy + 0.3 * ay, 1.0e-9

      :telemetry.detach(ref)
    end

    test "no blend one-shot fires when detection finds no face", %{image: image} do
      ref =
        attach_own_event_handlers(self(), [[:image_pipe, :transform, :detect, :blend]])

      state = %State{
        image: image,
        detector: {ImagePipe.Test.FakeDetector, [result: {:ok, []}]}
      }

      op = %Crop{
        width: {:pixels, 200},
        height: {:pixels, 200},
        crop_from: :gravity,
        gravity: {:smart, :face_assist}
      }

      {:ok, _} = Crop.execute(op, state)

      refute_received {[:image_pipe, :transform, :detect, :blend], ^ref, _, _}

      :telemetry.detach(ref)
    end
  end
end
