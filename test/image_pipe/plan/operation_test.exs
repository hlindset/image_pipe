defmodule ImagePipe.Plan.OperationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Colorize
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Sharpen

  describe "set_focus constructor (#321)" do
    test "builds a positional focus operation from a coordinate operand" do
      assert {:ok, %SetFocus{point: {:coord, {:px, 20}, {:px, 10}}}} =
               Operation.set_focus({:coord, {:px, 20}, {:px, 10}})

      assert {:ok, %SetFocus{point: {:coord, {:ratio, 3, 2}, {:ratio, 1, 2}}}} =
               Operation.set_focus({:coord, {:ratio, 3, 2}, {:ratio, 1, 2}})
    end

    test "builds a positional focus operation from an anchor operand" do
      assert {:ok, %SetFocus{point: {:anchor, :left, :top}}} =
               Operation.set_focus({:anchor, :left, :top})

      assert {:ok, %SetFocus{point: {:anchor, :right, :bottom}}} =
               Operation.set_focus({:anchor, :right, :bottom})
    end

    test "rejects malformed operands" do
      assert {:error, _} = Operation.set_focus({:coord, {:px, -5}, {:px, 10}})
      assert {:error, _} = Operation.set_focus({:anchor, :middle, :top})
      assert {:error, _} = Operation.set_focus(:nonsense)
    end

    test "a SetFocus op is a valid semantic operation" do
      {:ok, op} = Operation.set_focus({:coord, {:px, 20}, {:px, 10}})
      assert Operation.semantic?(op)
      {:ok, anchor} = Operation.set_focus({:anchor, :left, :top})
      assert Operation.semantic?(anchor)
    end
  end

  describe "carried guide (#321)" do
    test "carried is a valid crop and cover guide" do
      assert {:ok, %Operation.CropGuided{guide: :carried}} =
               Operation.crop_guided({:px, 100}, {:px, 100}, :carried)

      assert {:ok, %Operation.Resize{guide: :carried}} =
               Operation.resize(:cover, {:px, 100}, {:px, 100}, guide: :carried)
    end
  end

  describe "resize constructors" do
    test "build unified resize operations through exported constructor" do
      default_offset = {:pixels, 0.0}

      for mode <- [:fit, :cover, :stretch, :auto] do
        assert {:ok,
                %Operation.Resize{
                  mode: ^mode,
                  width: {:px, 300},
                  height: :auto,
                  dpr: {:ratio, 1, 1},
                  enlargement: :deny,
                  guide: :center,
                  x_offset: ^default_offset,
                  y_offset: ^default_offset,
                  min_width: nil,
                  min_height: nil,
                  zoom_x: 1.0,
                  zoom_y: 1.0
                }} = Operation.resize(mode, {:px, 300}, :auto)
      end
    end

    test "builds resize operation with explicit optional fields" do
      assert {:ok,
              %Operation.Resize{
                mode: :cover,
                width: {:px, 300},
                height: {:px, 200},
                dpr: {:ratio, 3, 2},
                enlargement: :allow,
                guide: {:anchor, :center, :bottom},
                x_offset: {:pixels, 12.0},
                y_offset: {:scale, -0.25},
                min_width: {:px, 100},
                min_height: {:px, 50},
                zoom_x: 1.25,
                zoom_y: 2
              }} =
               Operation.resize(:cover, {:px, 300}, {:px, 200},
                 dpr: "1.50",
                 enlargement: :allow,
                 guide: {:anchor, :center, :bottom},
                 x_offset: {:pixels, 12.0},
                 y_offset: {:scale, -0.25},
                 min_width: {:px, 100},
                 min_height: {:px, 50},
                 zoom_x: 1.25,
                 zoom_y: 2
               )
    end

    test "reject malformed resize construction without raising" do
      assert Operation.resize(:fill, {:px, 300}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fill, {:px, 300}, :auto, []]}}

      assert Operation.resize(:fit, {:px, 0}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 0}, :auto, []]}}

      assert Operation.resize(:fit, {:ratio, 1, 0}, :auto) ==
               {:error, {:invalid_operation, :resize, [:fit, {:ratio, 1, 0}, :auto, []]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, min_width: {:px, 0}) ==
               {:error,
                {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [min_width: {:px, 0}]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, dpr: 0) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [dpr: 0]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, dpr: "1.x") ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [dpr: "1.x"]]}}

      assert Operation.resize(:fit, {:px, 300}, :auto, zoom_x: 0) ==
               {:error, {:invalid_operation, :resize, [:fit, {:px, 300}, :auto, [zoom_x: 0]]}}

      assert Operation.resize(:cover, {:px, 300}, {:px, 200}, x_offset: {:scale, :bad}) ==
               {:error,
                {:invalid_operation, :resize,
                 [:cover, {:px, 300}, {:px, 200}, [x_offset: {:scale, :bad}]]}}

      assert {:ok, resize} =
               Operation.resize(:fit, {:px, 300}, :auto,
                 x_offset: {:scale, 0.0},
                 y_offset: 0
               )

      assert resize.x_offset == {:pixels, 0.0}
      assert resize.y_offset == {:pixels, 0.0}

      assert Operation.resize(:fit, {:px, 300}, :auto, x_offset: {:pixels, 1.0}) ==
               {:error,
                {:invalid_operation, :resize,
                 [:fit, {:px, 300}, :auto, [x_offset: {:pixels, 1.0}]]}}
    end
  end

  describe "resize/4 relative dimensions" do
    test "normalizes percent and scale width/height to an exact ratio" do
      assert {:ok, %Resize{width: {:ratio, 1, 2}, height: :auto}} =
               Operation.resize(:fit, {:percent, 50}, :auto)

      assert {:ok, %Resize{width: {:ratio, 1, 2}, height: {:px, 100}}} =
               Operation.resize(:cover, {:scale, 0.5}, {:px, 100})
    end

    test "rejects non-positive percent and scale" do
      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:percent, 0}, :auto)

      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:scale, -1.0}, :auto)
    end

    test "rejects a tiny positive percent/scale that rounds to a zero-extent ratio" do
      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:scale, 0.00000001}, :auto)

      assert {:error, {:invalid_operation, :resize, _}} =
               Operation.resize(:fit, {:percent, 0.00000001}, :auto)
    end

    test "still accepts px and auto" do
      assert {:ok, %Resize{width: {:px, 300}, height: :auto}} =
               Operation.resize(:fit, {:px, 300}, :auto)
    end
  end

  describe "crop constructors" do
    test "build crop operations through exported constructors" do
      default_offset = {:pixels, 0.0}

      assert {:ok,
              %{
                __struct__: Operation.CropGuided,
                width: {:px, 300},
                height: :full_axis,
                guide: :top_left,
                x_offset: ^default_offset,
                y_offset: {:scale, 0.25}
              }} =
               Operation.crop_guided({:px, 300}, :full_axis, :top_left, y_offset: {:scale, 0.25})

      assert {:ok,
              %{
                __struct__: Operation.CropRegion,
                x: {:ratio, 1, 10},
                y: {:px, 0},
                width: {:ratio, 1, 2},
                height: {:px, 100}
              }} =
               Operation.crop_region({:ratio, 1, 10}, {:px, 0}, {:ratio, 1, 2}, {:px, 100})
    end

    test "reject invalid crop constructor inputs without raising" do
      assert Operation.crop_guided({:px, 0}, :full_axis, :center) ==
               {:error, {:invalid_operation, :crop_guided, [{:px, 0}, :full_axis, :center, []]}}

      assert Operation.crop_guided({:px, 300}, :auto, :center) ==
               {:error, {:invalid_operation, :crop_guided, [{:px, 300}, :auto, :center, []]}}

      assert Operation.crop_guided({:px, 300}, :full_axis, {:anchor, :center, :middle}) ==
               {:error,
                {:invalid_operation, :crop_guided,
                 [{:px, 300}, :full_axis, {:anchor, :center, :middle}, []]}}

      assert Operation.crop_guided({:px, 300}, :full_axis, :center, gravity: :center) ==
               {:error, {:unknown_operation_options, :crop_guided, [:gravity]}}

      assert Operation.crop_region({:px, -1}, {:px, 0}, {:px, 100}, {:px, 100}) ==
               {:error,
                {:invalid_operation, :crop_region, [{:px, -1}, {:px, 0}, {:px, 100}, {:px, 100}]}}

      assert Operation.crop_region({:px, 0}, {:px, 0}, {:px, 0}, {:px, 100}) ==
               {:error,
                {:invalid_operation, :crop_region, [{:px, 0}, {:px, 0}, {:px, 0}, {:px, 100}]}}
    end

    test "allow zero crop region coordinates at construction" do
      assert Operation.crop_region({:px, 0}, {:ratio, 0, 1}, {:px, 100}, {:ratio, 1, 2}) ==
               {:ok,
                %{
                  __struct__: Operation.CropRegion,
                  x: {:px, 0},
                  y: {:ratio, 0, 1},
                  width: {:px, 100},
                  height: {:ratio, 1, 2}
                }}
    end

    test "allow focal crop guides with ratio coordinates" do
      assert Operation.crop_guided(
               {:px, 300},
               {:px, 200},
               {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}}
             ) ==
               {:ok,
                %{
                  __struct__: Operation.CropGuided,
                  width: {:px, 300},
                  height: {:px, 200},
                  guide: {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                  x_offset: {:pixels, 0.0},
                  y_offset: {:pixels, 0.0},
                  aspect_ratio: nil,
                  enlarge: false
                }}
    end

    test "crop_guided carries aspect_ratio and enlarge" do
      assert {:ok, %Operation.CropGuided{aspect_ratio: {:ratio, 3, 2}, enlarge: true}} =
               Operation.crop_guided({:px, 300}, {:px, 200}, :center,
                 aspect_ratio: {:ratio, 3, 2},
                 enlarge: true
               )
    end

    test "crop_guided defaults aspect_ratio to nil and enlarge to false" do
      assert {:ok, %Operation.CropGuided{aspect_ratio: nil, enlarge: false}} =
               Operation.crop_guided({:px, 300}, {:px, 200}, :center)
    end

    test "crop_guided rejects a malformed aspect_ratio" do
      assert {:error, _} =
               Operation.crop_guided({:px, 300}, {:px, 200}, :center, aspect_ratio: :bad)

      assert {:error, _} =
               Operation.crop_guided({:px, 300}, {:px, 200}, :center,
                 aspect_ratio: {:ratio, 0, 1}
               )
    end

    test "crop_guided rejects a non-boolean enlarge" do
      assert {:error, _} =
               Operation.crop_guided({:px, 300}, {:px, 200}, :center, enlarge: :yes)
    end
  end

  describe "canvas constructor" do
    test "builds canvas operation through exported constructor" do
      assert {:ok,
              %Operation.Canvas{
                width: {:px, 300},
                height: {:px, 200},
                placement: :center,
                fill: :transparent,
                overflow: :reject
              } = operation} =
               Operation.canvas({:px, 300}, {:px, 200}, :center, overflow: :reject)

      assert operation.x_offset == 0.0
      assert operation.y_offset == 0.0

      assert {:ok,
              %Operation.Canvas{
                width: {:ratio, 16, 9},
                height: {:ratio, 1, 1},
                placement: {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                x_offset: 5.0,
                y_offset: -3.0
              }} =
               Operation.canvas(
                 {:ratio, 16, 9},
                 {:ratio, 1, 1},
                 {:focal, {:ratio, 1, 3}, {:ratio, 2, 3}},
                 x_offset: 5.0,
                 y_offset: -3.0
               )
    end

    test "rejects unsupported canvas values without raising" do
      assert Operation.canvas(:full_axis, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [:full_axis, {:px, 200}, :center, []]}}

      assert Operation.canvas({:px, 0}, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [{:px, 0}, {:px, 200}, :center, []]}}

      assert Operation.canvas({:ratio, 16, 9}, {:px, 200}, :center) ==
               {:error, {:invalid_operation, :canvas, [{:ratio, 16, 9}, {:px, 200}, :center, []]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :middle) ==
               {:error, {:invalid_operation, :canvas, [{:px, 300}, {:px, 200}, :middle, []]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, fill: :white) ==
               {:error,
                {:invalid_operation, :canvas, [{:px, 300}, {:px, 200}, :center, [fill: :white]]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, overflow: :crop) ==
               {:error,
                {:invalid_operation, :canvas,
                 [{:px, 300}, {:px, 200}, :center, [overflow: :crop]]}}

      assert Operation.canvas({:px, 300}, {:px, 200}, :center, source: :image) ==
               {:error, {:unknown_operation_options, :canvas, [:source]}}
    end
  end

  describe "composition operation constructors" do
    test "canvas uses product-neutral fill instead of background" do
      assert {:ok, %Operation.Canvas{fill: :transparent}} =
               Operation.canvas({:px, 300}, {:px, 200}, :center)

      assert {:ok, red} = Operation.color(255, 0, 0)

      assert {:ok, %Operation.Canvas{fill: {:solid, ^red}}} =
               Operation.canvas({:px, 300}, {:px, 200}, :center, fill: {:solid, red})
    end

    test "padding stores logical sides, pixel ratio, and fill" do
      assert {:ok,
              %Operation.Padding{
                top: {:px, 1},
                right: {:px, 2},
                bottom: {:px, 3},
                left: {:px, 4},
                pixel_ratio: {:ratio, 3, 2},
                fill: :transparent
              }} =
               Operation.padding({:px, 1}, {:px, 2}, {:px, 3}, {:px, 4},
                 pixel_ratio: {:ratio, 3, 2}
               )
    end

    test "padding can request effective resize pixel ratio semantics" do
      assert {:ok,
              %Operation.Padding{
                pixel_ratio: {:effective, {:ratio, 3, 2}, :resize}
              }} =
               Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 3, 2}, :resize}
               )

      assert {:ok,
              %Operation.Padding{
                pixel_ratio: {:effective, {:ratio, 1, 2}, :canvas_preserving}
              }} =
               Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0},
                 pixel_ratio: {:effective, {:ratio, 1, 2}, :canvas_preserving}
               )
    end

    test "padding rejects all-zero and malformed sides" do
      assert Operation.padding({:px, 0}, {:px, 0}, {:px, 0}, {:px, 0}) ==
               {:error,
                {:invalid_operation, :padding, [{:px, 0}, {:px, 0}, {:px, 0}, {:px, 0}, []]}}

      assert Operation.padding({:px, -1}, {:px, 0}, {:px, 0}, {:px, 0}) ==
               {:error,
                {:invalid_operation, :padding, [{:px, -1}, {:px, 0}, {:px, 0}, {:px, 0}, []]}}

      assert Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0},
               pixel_ratio: {:effective, {:ratio, 1, 1}, :unknown}
             ) ==
               {:error,
                {:invalid_operation, :padding,
                 [
                   {:px, 1},
                   {:px, 0},
                   {:px, 0},
                   {:px, 0},
                   [pixel_ratio: {:effective, {:ratio, 1, 1}, :unknown}]
                 ]}}
    end

    test "background stores canonical alpha-capable color" do
      assert {:ok, red} = Operation.color(255, 0, 0, {:ratio, 1, 2})
      assert Operation.background(red) == {:ok, %Operation.Background{color: red}}
    end

    test "semantic validation accepts composition structs" do
      assert {:ok, padding} = Operation.padding({:px, 1}, {:px, 0}, {:px, 0}, {:px, 0})
      assert {:ok, red} = Operation.color(255, 0, 0)
      assert {:ok, background} = Operation.background(red)

      assert Operation.semantic?(padding)
      assert Operation.semantic?(background)

      refute Operation.semantic?(%Operation.Padding{
               top: {:px, 0},
               right: {:px, 0},
               bottom: {:px, 0},
               left: {:px, 0},
               pixel_ratio: {:ratio, 1, 1},
               fill: :transparent
             })
    end
  end

  describe "orientation operations" do
    test "allows semantic orientation operations" do
      assert Operation.semantic?(%Rotate{angle: 90})
      assert Operation.semantic?(%Flip{axis: :horizontal})
    end

    test "constructs semantic orientation operations" do
      assert Operation.rotate(90) == {:ok, %Rotate{angle: 90}}
      assert Operation.flip(:both) == {:ok, %Flip{axis: :both}}
    end

    test "rejects orientation values outside the explicit allowlist" do
      assert Operation.flip(:diagonal) == {:error, {:invalid_operation, :flip, [:diagonal]}}

      refute Operation.semantic?(%Flip{axis: :diagonal})
    end
  end

  describe "rotate/2 (arbitrary angle + mirror)" do
    test "accepts a right angle, mirror defaults false" do
      assert {:ok, %Rotate{angle: 90, mirror: false}} = Operation.rotate(90)
    end

    test "accepts an arbitrary float angle" do
      assert {:ok, %Rotate{angle: 45.5, mirror: false}} = Operation.rotate(45.5)
    end

    test "normalizes a whole-number float to an integer (lossless routing)" do
      assert {:ok, %Rotate{angle: 90, mirror: false}} = Operation.rotate(90.0)
    end

    test "normalizes 360 to 0" do
      assert {:ok, %Rotate{angle: 0}} = Operation.rotate(360)
    end

    test "normalizes 360.0 (float) to 0" do
      assert {:ok, %Rotate{angle: 0}} = Operation.rotate(360.0)
    end

    test "accepts mirror" do
      assert {:ok, %Rotate{angle: 90, mirror: true}} = Operation.rotate(90, true)
    end

    test "rejects out-of-range and non-numeric angles" do
      assert {:error, _} = Operation.rotate(-1)
      assert {:error, _} = Operation.rotate(361)
      assert {:error, _} = Operation.rotate("90")
    end

    test "semantic? accepts arbitrary + mirror, rejects out of range" do
      assert Operation.semantic?(%Rotate{angle: 45.5, mirror: true})
      assert Operation.semantic?(%Rotate{angle: 0, mirror: false})
      refute Operation.semantic?(%Rotate{angle: 360, mirror: false})
      refute Operation.semantic?(%Rotate{angle: -1, mirror: false})
    end
  end

  describe "trim/1" do
    test "builds a smart (:auto background) trim" do
      assert {:ok,
              %Operation.Trim{
                threshold: 12.0,
                background: :auto,
                equal_hor: false,
                equal_ver: false
              }} =
               Operation.trim(threshold: 12.0, background: :auto)
    end

    test "builds an explicit-color trim with equal flags" do
      {:ok, color} = Color.rgb(255, 0, 255)

      assert {:ok,
              %Operation.Trim{
                threshold: 5.0,
                background: ^color,
                equal_hor: true,
                equal_ver: true
              }} =
               Operation.trim(threshold: 5.0, background: color, equal_hor: true, equal_ver: true)
    end

    test "rejects a non-numeric threshold" do
      assert {:error, {:invalid_operation, :trim, _}} =
               Operation.trim(threshold: "x", background: :auto)
    end

    test "rejects a non-color, non-:auto background" do
      assert {:error, {:invalid_operation, :trim, _}} =
               Operation.trim(threshold: 1.0, background: :nope)
    end

    test "semantic? accepts a valid Trim and rejects a malformed one" do
      {:ok, op} = Operation.trim(threshold: 1.0, background: :auto)
      assert Operation.semantic?(op)

      refute Operation.semantic?(%Operation.Trim{
               threshold: "x",
               background: :auto,
               equal_hor: false,
               equal_ver: false
             })
    end
  end

  describe "effect operations" do
    test "constructs semantic effect operations" do
      assert Operation.blur(2.5) == {:ok, %Blur{sigma: 2.5}}
      assert Operation.sharpen(0.7) == {:ok, %Sharpen{sigma: 0.7}}
      assert Operation.pixelate(8) == {:ok, %Pixelate{size: 8}}
      assert {:ok, color} = Operation.color(255, 204, 0)

      assert Operation.monochrome({:ratio, 1, 2}, color) ==
               {:ok, %Monochrome{intensity: {:ratio, 1, 2}, color: color}}

      assert {:ok, shadow} = Operation.color(17, 34, 51)
      assert {:ok, highlight} = Operation.color(255, 238, 204)

      assert Operation.duotone({:ratio, 1, 4}, shadow, highlight) ==
               {:ok,
                %Duotone{
                  intensity: {:ratio, 1, 4},
                  shadow: shadow,
                  highlight: highlight
                }}

      assert Operation.brightness(20) == {:ok, %Brightness{value: 20}}
      assert Operation.contrast(1.5) == {:ok, %Contrast{value: 1.5}}
      assert Operation.saturation(1.5) == {:ok, %Saturation{value: 1.5}}

      assert Operation.semantic?(%Blur{sigma: 2.5})
      assert Operation.semantic?(%Sharpen{sigma: 0.7})
      assert Operation.semantic?(%Pixelate{size: 8})
      assert Operation.semantic?(%Monochrome{intensity: {:ratio, 1, 2}, color: color})

      assert Operation.semantic?(%Duotone{
               intensity: {:ratio, 1, 4},
               shadow: shadow,
               highlight: highlight
             })

      assert Operation.semantic?(%Brightness{value: 20})
      assert Operation.semantic?(%Contrast{value: 1.5})
      assert Operation.semantic?(%Saturation{value: 1.5})
    end

    test "colorize/3 validates opacity ratio, color, keep_alpha" do
      {:ok, color} = Operation.color(0, 0, 0)

      assert {:ok, %Colorize{opacity: {:ratio, 1, 2}, keep_alpha: true}} =
               Operation.colorize({:ratio, 1, 2}, color, true)

      assert {:error, _} = Operation.colorize({:ratio, 0, 1}, color, false)
      assert {:error, _} = Operation.colorize({:ratio, 1, 2}, :not_a_color, false)
    end

    test "gradient/5 validates fields and rejects start/stop outside [0,1]" do
      {:ok, color} = Operation.color(0, 0, 0)

      assert {:ok, gradient} = Operation.gradient({:ratio, 1, 2}, color, 90.0, 0.0, 1.0)
      assert %Operation.Gradient{angle: 90.0, start: start, stop: stop} = gradient
      assert start == 0.0
      assert stop == 1.0

      assert {:error, _} = Operation.gradient({:ratio, 0, 1}, color, 0.0, 0.0, 1.0)
      assert {:error, _} = Operation.gradient({:ratio, 1, 2}, color, 0.0, -0.1, 1.0)
    end

    test "rejects non-positive effect values" do
      assert Operation.blur(0) == {:error, {:invalid_operation, :blur, [0]}}
      assert Operation.sharpen(-1.0) == {:error, {:invalid_operation, :sharpen, [-1.0]}}
      assert Operation.pixelate(0) == {:error, {:invalid_operation, :pixelate, [0]}}
      assert {:ok, color} = Operation.color(255, 204, 0)

      assert Operation.monochrome({:ratio, 0, 1}, color) ==
               {:error, {:invalid_operation, :monochrome, [{:ratio, 0, 1}, color]}}

      refute Operation.semantic?(%Blur{sigma: 0})
      refute Operation.semantic?(%Sharpen{sigma: -1.0})
      refute Operation.semantic?(%Pixelate{size: 0})
      refute Operation.semantic?(%Monochrome{intensity: {:ratio, 0, 1}, color: color})
    end

    test "rejects out-of-range adjustment values" do
      assert Operation.brightness(256) == {:error, {:invalid_operation, :brightness, [256]}}
      assert Operation.brightness(-256) == {:error, {:invalid_operation, :brightness, [-256]}}
      assert Operation.contrast(0) == {:error, {:invalid_operation, :contrast, [0]}}
      assert Operation.contrast(-1.5) == {:error, {:invalid_operation, :contrast, [-1.5]}}
      assert Operation.saturation(0) == {:error, {:invalid_operation, :saturation, [0]}}
      assert Operation.saturation(-1.5) == {:error, {:invalid_operation, :saturation, [-1.5]}}

      refute Operation.semantic?(%Brightness{value: 256})
      refute Operation.semantic?(%Contrast{value: 0})
      refute Operation.semantic?(%Saturation{value: -1.5})
    end
  end
end
