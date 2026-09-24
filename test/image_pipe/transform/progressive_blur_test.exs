defmodule ImagePipe.Transform.ProgressiveBlurTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  property "streamed and random inputs agree across sizes, angles, stops, and sigmas" do
    check all width <- integer(1..70),
              height <- integer(1..70),
              sigma <- member_of([0.01, 0.1, 0.5, 2, 12]),
              angle <- member_of([-45, 0, 90, 180, 270]),
              stops <- member_of(["0,1", "1,0", "0.5,0.5", "0.2,0.8"]),
              max_runs: 30 do
      body =
        Image.new!(width, height, color: [80, 120, 160])
        |> Image.Draw.rect!(0, 0, max(1, div(width, 2)), max(1, div(height, 2)), color: :white)
        |> Image.write!(:memory, suffix: ".png")

      assert {:ok, lexed} =
               Plug.Test.conn(:get, "/progressive-blur=#{sigma},#{angle},#{stops}/src/image.png")
               |> Path.extract()

      assert {:ok, request} = Parser.parse(lexed, [])
      assert {:ok, sequential} = Image.open([body], access: :sequential, fail_on: :error)
      assert {:ok, random} = Image.from_binary(body, access: :random)
      assert {:ok, actual} = Executor.execute(%State{image: sequential}, request, [])
      assert {:ok, expected} = Executor.execute(%State{image: random}, request, [])
      assert {:ok, pixels} = VipsImage.write_to_binary(actual.image)
      assert {:ok, ^pixels} = VipsImage.write_to_binary(expected.image)
      assert {Image.width(actual.image), Image.height(actual.image)} == {width, height}
    end
  end
end
