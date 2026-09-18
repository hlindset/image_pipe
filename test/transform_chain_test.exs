defmodule ImagePipe.Transform.ChainTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.ChainTest.FailingTransform
  alias ImagePipe.Transform.ChainTest.UnexpectedTransform
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Brightness
  alias ImagePipe.Transform.Operation.Contrast
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Saturation
  alias ImagePipe.Transform.State

  doctest ImagePipe.Transform.Chain

  test "transform name is delegated to operation module" do
    operation = %Resize{mode: :fit, width: {:pixels, 10}, height: :auto}

    assert Transform.transform_name(operation) == :resize
    assert Transform.transform_name(%Brightness{value: 20}) == :brightness
    assert Transform.transform_name(%Contrast{value: -15}) == :contrast
    assert Transform.transform_name(%Saturation{value: 35}) == :saturation
  end

  test "stops executing after the first transform error" do
    {:ok, image} = Image.new(20, 20, color: :white)

    chain = [
      %FailingTransform{},
      %UnexpectedTransform{}
    ]

    assert {:error, {:transform_error, {FailingTransform, :failed}}} =
             Chain.execute(%State{image: image}, chain)
  end

  test "neutral resize and canvas operations execute through the chain" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{mode: :fit, width: {:pixels, 100}, height: {:pixels, 100}},
      %ExtendCanvas{rule: {:dimensions, {:pixels, 100}, {:pixels, 100}}}
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "fill resize crops non-square sources to the requested box" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}},
      %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:anchor, :center, :center}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "fill result crop applies non-center gravity after resize" do
    image =
      300
      |> Image.new!(100, color: :black)
      |> Image.Draw.rect!(0, 0, 100, 100, color: :red)
      |> Image.Draw.rect!(100, 0, 100, 100, color: :green)
      |> Image.Draw.rect!(200, 0, 100, 100, color: :blue)

    chain = [
      %Resize{mode: :fill, width: {:pixels, 100}, height: {:pixels, 100}},
      %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:anchor, :right, :center}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 50, 50) == [0, 0, 255]
  end

  test "gravity crop uses current-image center rounding" do
    image =
      401
      |> Image.new!(300, color: :black)
      |> Image.Draw.rect!(151, 100, 1, 1, color: :red)

    chain = [
      %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:anchor, :center, :center}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0]
  end

  test "focal-point gravity clamps crop into current image bounds" do
    image =
      300
      |> Image.new!(100, color: :black)
      |> Image.Draw.rect!(0, 0, 100, 100, color: :red)
      |> Image.Draw.rect!(100, 0, 100, 100, color: :green)
      |> Image.Draw.rect!(200, 0, 100, 100, color: :blue)

    chain = [
      %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:fp, 1.0, 0.5}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 50, 50) == [0, 0, 255]
  end

  test "fill resize crops to min-adjusted target dimensions" do
    for mode <- [:fill, :fill_down] do
      {:ok, image} = Image.new(1000, 500, color: :white)

      chain = [
        %Resize{
          mode: mode,
          width: {:pixels, 100},
          height: {:pixels, 100},
          min_width: {:pixels, 300}
        },
        %Crop{
          width: {:pixels, 300},
          height: {:pixels, 300},
          crop_from: :gravity,
          gravity: {:anchor, :center, :center}
        }
      ]

      assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
      assert Image.width(image) == 300
      assert Image.height(image) == 300
    end
  end

  test "fill-down crops clamped images to the requested aspect ratio" do
    {:ok, image} = Image.new(200, 100, color: :white)

    chain = [
      %Resize{mode: :fill_down, width: {:pixels, 300}, height: {:pixels, 300}, enlarge: true},
      %Crop{
        width: {:pixels, 100},
        height: {:pixels, 100},
        crop_from: :gravity,
        gravity: {:anchor, :center, :center}
      }
    ]

    assert {:ok, %State{image: image}} = Chain.execute(%State{image: image}, chain)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "background composites alpha onto a transparent source" do
    {:ok, image} = Image.new(2, 2, color: [0, 0, 0, 0])

    assert {:ok, %State{image: image}} =
             Chain.execute(%State{image: image}, [%Background{color: [255, 0, 0, 128]}])

    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0, 128]
  end

  describe "per-op materialization" do
    test "a chain with a materializing op sets materialized? and stays correct" do
      {:ok, image} = Image.new(40, 20, color: :white)

      {:ok, state} =
        Chain.execute(%State{image: image, materialized?: false}, [smart_crop(20, 10)])

      assert state.materialized? == true
      assert Image.width(state.image) == 20
      assert Image.height(state.image) == 10
    end

    test "a second materializing op produces correct output (no double-copy regression)" do
      {:ok, image} = Image.new(40, 20, color: :white)

      {:ok, state} =
        Chain.execute(%State{image: image, materialized?: false}, [
          smart_crop(30, 16),
          smart_crop(20, 10)
        ])

      assert state.materialized? == true
      assert Image.width(state.image) == 20
      assert Image.height(state.image) == 10
    end

    test "a fully sequential-safe chain leaves materialized? false" do
      {:ok, image} = Image.new(40, 20, color: :white)

      {:ok, state} =
        Chain.execute(%State{image: image, materialized?: false}, [
          %Background{color: [0, 0, 0, 255]}
        ])

      assert state.materialized? == false
    end

    test "a materializing op on a corrupt sequential image returns {:materialize_error, _}, not {:transform_error, _}" do
      # Open just enough bytes to satisfy the JPEG header parser but not enough to
      # read all pixel data. copy_memory fails when the materializing crop tries to
      # pull pixels from the truncated sequential stream.
      body = File.read!("priv/static/images/beach.jpg")
      truncated = binary_part(body, 0, 5000)
      {:ok, image} = Image.open([truncated], access: :sequential, fail_on: :error)

      assert {:error, {:materialize_error, _}} =
               Chain.execute(%State{image: image}, [smart_crop(20, 10)])
    end
  end

  defp smart_crop(width, height) do
    %Crop{
      width: {:pixels, width},
      height: {:pixels, height},
      crop_from: :gravity,
      gravity: :smart
    }
  end

  test "execute/3 emits [:transform, :operation] spans in order with operation metadata" do
    test_pid = self()
    handler = {__MODULE__, :telemetry_handler, System.unique_integer([:positive])}

    :telemetry.attach_many(
      handler,
      [
        [:image_pipe, :transform, :operation, :start],
        [:image_pipe, :transform, :operation, :stop]
      ],
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, image} = Image.new(10, 10)

    chain = [
      %ImagePipe.Transform.Operation.Blur{sigma: 1.0},
      %ImagePipe.Transform.Operation.Blur{sigma: 2.0}
    ]

    assert {:ok, %State{}} = Chain.execute(%State{image: image}, chain)

    assert_received {:telemetry, [:image_pipe, :transform, :operation, :start], _m,
                     %{operation: :blur, index: 0}}

    assert_received {:telemetry, [:image_pipe, :transform, :operation, :stop], %{duration: _},
                     %{operation: :blur, index: 0, result: :ok}}

    assert_received {:telemetry, [:image_pipe, :transform, :operation, :start], _m2,
                     %{operation: :blur, index: 1}}

    assert_received {:telemetry, [:image_pipe, :transform, :operation, :stop], %{duration: _},
                     %{operation: :blur, index: 1, result: :ok}}
  end
end
