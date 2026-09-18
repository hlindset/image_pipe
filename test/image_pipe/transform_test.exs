defmodule ImagePipe.TransformTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Operation.Background
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.State

  test "resize and canvas operations share the resulting state" do
    {:ok, image} = Image.new(200, 100, color: :white)

    assert {:ok, state} = Transform.run(%State{image: image}, %Resize{width: 100, height: 50})

    assert {:ok, %State{image: image}} =
             Transform.run(state, %ExtendCanvas{rule: {:dimensions, 100, 100}})

    assert Image.width(image) == 100
    assert Image.height(image) == 100
  end

  test "fill resize crops non-square sources to the requested box" do
    {:ok, image} = Image.new(200, 100, color: :white)

    assert {:ok, state} = Transform.run(%State{image: image}, %Resize{width: 200, height: 100})

    crop = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center}
    }

    assert {:ok, %State{image: image}} = Transform.run(state, crop)
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

    assert {:ok, state} = Transform.run(%State{image: image}, %Resize{width: 300, height: 100})

    crop = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: {:anchor, :right, :center}
    }

    assert {:ok, %State{image: image}} = Transform.run(state, crop)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 50, 50) == [0, 0, 255]
  end

  test "gravity crop uses current-image center rounding" do
    image =
      401
      |> Image.new!(300, color: :black)
      |> Image.Draw.rect!(151, 100, 1, 1, color: :red)

    crop = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: {:anchor, :center, :center}
    }

    assert {:ok, %State{image: image}} = Transform.run(%State{image: image}, crop)
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

    crop = %Crop{
      width: {:pixels, 100},
      height: {:pixels, 100},
      crop_from: :gravity,
      gravity: {:fp, 1.0, 0.5}
    }

    assert {:ok, %State{image: image}} = Transform.run(%State{image: image}, crop)
    assert Image.width(image) == 100
    assert Image.height(image) == 100
    assert Image.get_pixel!(image, 50, 50) == [0, 0, 255]
  end

  test "background composites alpha onto a transparent source" do
    {:ok, image} = Image.new(2, 2, color: [0, 0, 0, 0])

    assert {:ok, %State{image: image}} =
             Transform.run(%State{image: image}, %Background{color: [255, 0, 0, 128]})

    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0, 128]
  end

  describe "per-op materialization" do
    test "a materializing operation sets materialized? and stays correct" do
      {:ok, image} = Image.new(40, 20, color: :white)

      {:ok, state} =
        Transform.run(%State{image: image}, smart_crop(20, 10))

      assert state.materialized? == true
      assert Image.width(state.image) == 20
      assert Image.height(state.image) == 10
    end

    test "a second materializing operation reuses the memory-backed image" do
      {:ok, image} = Image.new(40, 20, color: :white)
      prefix = [__MODULE__, :materialize_once]
      opts = [telemetry_prefix: prefix]
      attach_events(prefix, [[:transform, :materialize, :stop]])

      assert {:ok, state} =
               Transform.run(%State{image: image, telemetry_opts: opts}, smart_crop(30, 16), opts)

      assert {:ok, state} = Transform.run(state, smart_crop(20, 10), opts)

      assert state.materialized? == true
      assert Image.width(state.image) == 20
      assert Image.height(state.image) == 10
      event = prefix ++ [:transform, :materialize, :stop]
      assert_received {:telemetry, ^event, _, %{result: :ok}}
      refute_received {:telemetry, ^event, _, _}
    end

    test "a sequential-safe operation leaves materialized? false" do
      {:ok, image} = Image.new(40, 20, color: :white)

      {:ok, state} =
        Transform.run(%State{image: image}, %Background{color: [0, 0, 0, 255]})

      assert state.materialized? == false
    end

    test "a corrupt sequential image returns a decode error during materialization" do
      # Open just enough bytes to satisfy the JPEG header parser but not enough to
      # read all pixel data. copy_memory fails when the materializing crop tries to
      # pull pixels from the truncated sequential stream.
      body = File.read!("priv/static/images/beach.jpg")
      truncated = binary_part(body, 0, 5000)
      {:ok, image} = Image.open([truncated], access: :sequential, fail_on: :error)

      assert {:error, {:decode, _}} =
               Transform.run(%State{image: image}, smart_crop(20, 10))
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

  test "run emits operation parameters, outcome, and resulting dimensions" do
    prefix = [__MODULE__, :operation_metadata]
    opts = [telemetry_prefix: prefix]
    attach_events(prefix, [[:transform, :operation, :start], [:transform, :operation, :stop]])
    {:ok, image} = Image.new(10, 10)
    operation = %Blur{sigma: 1.0}

    assert {:ok, %State{}} = Transform.run(%State{image: image}, operation, opts)

    start_event = prefix ++ [:transform, :operation, :start]
    stop_event = prefix ++ [:transform, :operation, :stop]

    assert_received {:telemetry, ^start_event, _, %{operation: :blur, params: ^operation}}

    assert_received {:telemetry, ^stop_event, %{duration: _},
                     %{operation: :blur, params: ^operation, result: :ok, dims: {10, 10}}}
  end

  defp attach_events(prefix, suffixes) do
    test_pid = self()
    handler = {__MODULE__, :telemetry_handler, System.unique_integer([:positive])}

    :telemetry.attach_many(
      handler,
      Enum.map(suffixes, &(prefix ++ &1)),
      fn event, measurements, metadata, _ ->
        send(test_pid, {:telemetry, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end
end
