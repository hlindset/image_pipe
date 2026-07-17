defmodule ImagePipe.Plan.OperationKeyDataTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.KeyData
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Colorize
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gradient
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.Sharpen

  describe "tagged geometry data" do
    test "returns key data for symbolic dimensions" do
      assert KeyData.data(:auto) == [unit: :auto]
      assert KeyData.data(:full_axis) == [unit: :full_axis]
    end

    test "returns key data for logical pixel dimensions" do
      assert KeyData.data({:px, 300}) == [unit: :logical_px, value: 300]
    end

    test "canonicalizes ratio dimensions" do
      assert KeyData.data({:ratio, 6, 8}) == [unit: :ratio, numerator: 3, denominator: 4]
      assert KeyData.data({:ratio, 0, 10}) == [unit: :ratio, numerator: 0, denominator: 1]
    end
  end

  describe "DPR data" do
    test "canonicalizes equivalent DPR ones" do
      expected = [unit: :ratio, numerator: 1, denominator: 1]

      for dpr <- [1, 1.0, "1.00"] do
        assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: dpr)
        assert KeyData.data(operation)[:dpr] == expected
      end
    end

    test "canonicalizes floats through fixed decimal precision" do
      assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: 1.3324232)

      assert KeyData.data(operation)[:dpr] == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]
    end

    test "parses decimal strings exactly" do
      assert {:ok, seven_places} =
               Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.3324232")

      assert KeyData.data(seven_places)[:dpr] == [
               unit: :ratio,
               numerator: 1_665_529,
               denominator: 1_250_000
             ]

      assert {:ok, eight_places} =
               Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.33242321")

      assert KeyData.data(eight_places)[:dpr] == [
               unit: :ratio,
               numerator: 133_242_321,
               denominator: 100_000_000
             ]
    end
  end

  describe "resize operation data" do
    test "returns key data for unresolved resize auto semantic intent" do
      assert {:ok, operation} =
               Operation.resize(:auto, {:px, 300}, {:px, 200},
                 dpr: 2.0,
                 x_offset: {:pixels, 8.0},
                 y_offset: {:scale, -0.25}
               )

      data = KeyData.data(operation)

      assert data == [
               op: :resize,
               mode: :auto,
               width: [unit: :logical_px, value: 300],
               height: [unit: :logical_px, value: 200],
               dpr: [unit: :ratio, numerator: 2, denominator: 1],
               enlargement: :deny,
               guide: :center,
               x_offset: {:pixels, 8.0},
               y_offset: {:scale, -0.25},
               min_width: nil,
               min_height: nil,
               max_width: nil,
               max_height: nil,
               max_area: nil,
               zoom_x: 1.0,
               zoom_y: 1.0,
               rule: :auto_orientation_match_v1
             ]

      refute Keyword.has_key?(data, :selected_branch)
      refute Keyword.has_key?(data, :branch)
      refute inspect(data) =~ "resize_fit"
      refute inspect(data) =~ "resize_cover"
    end

    test "canonicalizes equivalent DPR values through operation key data" do
      expected_dpr = [unit: :ratio, numerator: 1, denominator: 1]

      for dpr <- [1, 1.0, "1.00"] do
        assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, dpr: dpr)
        assert KeyData.data(operation)[:dpr] == expected_dpr
      end
    end
  end

  describe "crop operation data" do
    test "returns key data for guided crop semantic intent" do
      assert {:ok, operation} =
               Operation.crop_guided(
                 {:px, 300},
                 :full_axis,
                 {:anchor, :left, :top},
                 x_offset: {:pixels, 4},
                 y_offset: {:scale, 0.25}
               )

      assert KeyData.data(operation) == [
               op: :crop_guided,
               width: [unit: :logical_px, value: 300],
               height: [unit: :full_axis],
               guide: [type: :anchor, x: :left, y: :top],
               x_offset: {:pixels, 4},
               y_offset: {:scale, 0.25},
               aspect_ratio: nil,
               enlarge: false
             ]
    end

    test "returns key data for crop region without coordinate-space fields" do
      assert {:ok, operation} =
               Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:ratio, 1, 2}, {:px, 100})

      data = KeyData.data(operation)

      assert data == [
               op: :crop_region,
               x: [unit: :logical_px, value: 0],
               y: [unit: :ratio, numerator: 0, denominator: 1],
               width: [unit: :ratio, numerator: 1, denominator: 2],
               height: [unit: :logical_px, value: 100],
               on_out_of_bounds: :clamp
             ]

      refute Keyword.has_key?(data, :space)
      refute Keyword.has_key?(data, :coordinate_space)
    end

    test "returns key data for a focal-guided crop" do
      assert {:ok, operation} =
               Operation.crop_guided(
                 {:px, 300},
                 :full_axis,
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}}
               )

      assert KeyData.data(operation)[:guide] == [
               type: :focal,
               x: [unit: :ratio, numerator: 1, denominator: 3],
               y: [unit: :ratio, numerator: 2, denominator: 3]
             ]
    end

    test "crop_guided key data includes aspect_ratio and enlarge" do
      {:ok, op} =
        Operation.crop_guided({:px, 300}, {:px, 200}, :center,
          aspect_ratio: {:ratio, 1, 1},
          enlarge: true
        )

      data = KeyData.data(op)
      assert data[:aspect_ratio] == [unit: :ratio, numerator: 1, denominator: 1]
      assert data[:enlarge] == true
    end
  end

  describe "canvas operation data" do
    test "returns key data for canvas semantic intent" do
      assert {:ok, operation} =
               Operation.canvas(
                 {:ratio, 16, 9},
                 {:ratio, 1, 1},
                 :top_left,
                 x_offset: 5.0,
                 y_offset: -3.0
               )

      assert KeyData.data(operation) == [
               op: :canvas,
               width: [unit: :ratio, numerator: 16, denominator: 9],
               height: [unit: :ratio, numerator: 1, denominator: 1],
               placement: :top_left,
               fill: :transparent,
               overflow: :reject,
               x_offset: 5.0,
               y_offset: -3.0
             ]
    end

    test "returns key data for a focal canvas placement" do
      assert {:ok, operation} =
               Operation.canvas(
                 {:ratio, 16, 9},
                 {:ratio, 1, 1},
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}}
               )

      assert KeyData.data(operation)[:placement] == [
               type: :focal,
               x: [unit: :ratio, numerator: 1, denominator: 3],
               y: [unit: :ratio, numerator: 2, denominator: 3]
             ]
    end
  end

  describe "orientation operation data" do
    test "returns key data for semantic orientation operations" do
      assert KeyData.data(%Rotate{angle: 270}) == [op: :rotate, angle: 270, mirror: false]
      assert KeyData.data(%Flip{axis: :both}) == [op: :flip, axis: :both]
    end
  end

  describe "effect operation data" do
    test "returns key data for semantic effect operations" do
      assert KeyData.data(%Blur{sigma: 2.5}) == [op: :blur, sigma: 2.5]
      assert KeyData.data(%Sharpen{sigma: 0.7}) == [op: :sharpen, sigma: 0.7]
      assert KeyData.data(%Pixelate{size: 8}) == [op: :pixelate, size: 8]
      assert {:ok, color} = Operation.color(255, 204, 0)

      assert KeyData.data(%Monochrome{intensity: {:ratio, 1, 2}, color: color}) == [
               op: :monochrome,
               intensity: [unit: :ratio, numerator: 1, denominator: 2],
               color: KeyData.data(%ImagePipe.Plan.Operation.Background{color: color})[:color]
             ]

      assert {:ok, shadow} = Operation.color(17, 34, 51)
      assert {:ok, highlight} = Operation.color(255, 238, 204)

      assert KeyData.data(%Duotone{
               intensity: {:ratio, 1, 4},
               shadow: shadow,
               highlight: highlight
             }) == [
               op: :duotone,
               intensity: [unit: :ratio, numerator: 1, denominator: 4],
               shadow: KeyData.data(%ImagePipe.Plan.Operation.Background{color: shadow})[:color],
               highlight:
                 KeyData.data(%ImagePipe.Plan.Operation.Background{color: highlight})[:color]
             ]

      assert KeyData.data(%Brightness{value: 20}) == [op: :brightness, value: 20]
      assert KeyData.data(%Contrast{value: 1.5}) == [op: :contrast, value: 1.5]
      assert KeyData.data(%Saturation{value: 1.5}) == [op: :saturation, value: 1.5]
    end

    test "returns key data for colorize covering opacity, color, and keep_alpha" do
      {:ok, black} = Operation.color(0, 0, 0)
      {:ok, white} = Operation.color(255, 255, 255)

      base = %Colorize{opacity: {:ratio, 1, 2}, color: black, keep_alpha: false}

      assert KeyData.data(base) == [
               op: :colorize,
               opacity: [unit: :ratio, numerator: 1, denominator: 2],
               color: Color.key_data(black),
               keep_alpha: false
             ]

      different_opacity = %Colorize{base | opacity: {:ratio, 1, 4}}
      different_color = %Colorize{base | color: white}
      different_keep_alpha = %Colorize{base | keep_alpha: true}

      refute KeyData.data(base) == KeyData.data(different_opacity)
      refute KeyData.data(base) == KeyData.data(different_color)
      refute KeyData.data(base) == KeyData.data(different_keep_alpha)
    end

    test "returns key data for gradient covering opacity, color, angle, start, and stop" do
      {:ok, black} = Operation.color(0, 0, 0)
      {:ok, white} = Operation.color(255, 255, 255)

      base = %Gradient{
        opacity: {:ratio, 1, 2},
        color: black,
        angle: 90.0,
        start: 0.0,
        stop: 1.0
      }

      assert KeyData.data(base) == [
               op: :gradient,
               opacity: [unit: :ratio, numerator: 1, denominator: 2],
               color: Color.key_data(black),
               angle: 90.0,
               start: 0.0,
               stop: 1.0
             ]

      different_opacity = %Gradient{base | opacity: {:ratio, 1, 4}}
      different_color = %Gradient{base | color: white}
      different_angle = %Gradient{base | angle: 270.0}
      different_start = %Gradient{base | start: 0.25}
      different_stop = %Gradient{base | stop: 0.75}

      refute KeyData.data(base) == KeyData.data(different_opacity)
      refute KeyData.data(base) == KeyData.data(different_color)
      refute KeyData.data(base) == KeyData.data(different_angle)
      refute KeyData.data(base) == KeyData.data(different_start)
      refute KeyData.data(base) == KeyData.data(different_stop)
    end
  end

  describe "guide_data via CropGuided cache data" do
    alias ImagePipe.Plan.Operation.CropGuided

    test "detect :all guide encodes as classes: :all" do
      data =
        KeyData.data(%CropGuided{
          width: {:px, 100},
          height: {:px, 100},
          guide: {:detect, {:all, %{}}}
        })

      assert Keyword.fetch!(data, :guide) == [type: :detect, classes: :all, weights: %{}]
    end

    property "detect-guide class order does not change the guide key data" do
      all_classes = ["car", "dog", "cat", "person", "bird", "truck", "bus", "boat"]

      check all classes <-
                  list_of(member_of(all_classes), min_length: 1, max_length: 4)
                  |> map(&Enum.uniq/1) do
        a =
          KeyData.data(%CropGuided{
            width: {:px, 100},
            height: {:px, 100},
            guide: {:detect, {classes, %{}}}
          })

        b =
          KeyData.data(%CropGuided{
            width: {:px, 100},
            height: {:px, 100},
            guide: {:detect, {Enum.shuffle(classes), %{}}}
          })

        assert a == b
      end
    end

    test "the three content-aware guides serialize distinctly" do
      smart = KeyData.data(%CropGuided{width: {:px, 10}, height: {:px, 10}, guide: :smart})

      assist =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:smart, :face_assist}
        })

      detect =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {["face"], %{}}}
        })

      guides = Enum.map([smart, assist, detect], &Keyword.fetch!(&1, :guide))
      assert guides == Enum.uniq(guides)
    end

    test "detect classes are sorted and serialized as strings" do
      a =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {["b", "a"], %{}}}
        })

      b =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {["a", "b"], %{}}}
        })

      assert Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end

    test "detect weights are key material" do
      a =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {:all, %{"face" => 3.0}}}
        })

      b =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {:all, %{"face" => 2.0}}}
        })

      refute Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end

    # Spec-mandated: key_data does NOT re-canonicalize — it passes an already-
    # canonical weights map through unchanged, so the parser (sole canonicalizer)
    # and the cache layer cannot drift.
    property "guide_data passes an already-canonical weights map through unchanged" do
      check all entries <-
                  list_of({member_of(["face", "car", "dog"]), member_of([2.0, 3.0])},
                    max_length: 3
                  ),
                default <- member_of([:none, 2.0, 3.0]) do
        weights =
          entries
          |> Map.new()
          |> then(fn m -> if default == :none, do: m, else: Map.put(m, :default, default) end)

        data =
          KeyData.data(%CropGuided{
            width: {:px, 10},
            height: {:px, 10},
            guide: {:detect, {:all, weights}}
          })

        assert Keyword.get(Keyword.fetch!(data, :guide), :weights) == weights
      end
    end

    test "equal detect weights serialize identically regardless of map insertion order" do
      a =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {:all, %{:default => 2.0, "face" => 3.0}}}
        })

      b =
        KeyData.data(%CropGuided{
          width: {:px, 10},
          height: {:px, 10},
          guide: {:detect, {:all, Map.new([{"face", 3.0}, {:default, 2.0}])}}
        })

      assert Keyword.fetch!(a, :guide) == Keyword.fetch!(b, :guide)
    end
  end

  describe "KeyData.data/1 for Trim" do
    test "different thresholds produce different key data" do
      {:ok, a} = Operation.trim(threshold: 10.0, background: :auto)
      {:ok, b} = Operation.trim(threshold: 20.0, background: :auto)
      assert KeyData.data(a) != KeyData.data(b)
    end

    test "different backgrounds produce different key data; equal trims collide" do
      {:ok, magenta} = Color.rgb(255, 0, 255)
      {:ok, auto} = Operation.trim(threshold: 10.0, background: :auto)
      {:ok, color} = Operation.trim(threshold: 10.0, background: magenta)
      {:ok, auto2} = Operation.trim(threshold: 10.0, background: :auto)

      assert KeyData.data(auto) != KeyData.data(color)
      assert KeyData.data(auto) == KeyData.data(auto2)
    end
  end
end
