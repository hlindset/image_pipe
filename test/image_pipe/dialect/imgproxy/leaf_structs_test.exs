defmodule ImagePipe.Dialect.Imgproxy.LeafStructsTest do
  use ExUnit.Case, async: true

  # The phase-1 dialect copies of the imgproxy leaf request structs must carry
  # the framework originals' fields and defaults exactly: Tasks 7-9 and 12 port
  # the framework's grammar and geometry onto these structs, so any drift in a
  # field name or default silently changes dialect behavior against the frozen
  # framework arm the dual-run suite compares it to.

  test "PipelineRequest copy carries identical fields and defaults" do
    original = Map.from_struct(%ImagePipe.Parser.Imgproxy.PipelineRequest{})
    copy = Map.from_struct(%ImagePipe.Dialect.Imgproxy.PipelineRequest{})

    # Effects sub-structs differ by module name; compare shapes.
    assert Map.keys(original) == Map.keys(copy)

    assert Map.drop(original, [:effects, :orientation]) ==
             Map.drop(copy, [:effects, :orientation])

    assert Map.from_struct(original.effects) == Map.from_struct(copy.effects)
    assert Map.from_struct(original.orientation) == Map.from_struct(copy.orientation)
  end

  test "Effects copy carries identical fields and defaults" do
    assert Map.from_struct(%ImagePipe.Parser.Imgproxy.Effects{}) ==
             Map.from_struct(%ImagePipe.Dialect.Imgproxy.Effects{})
  end

  test "CropRequest copy carries identical fields and defaults" do
    assert Map.from_struct(%ImagePipe.Parser.Imgproxy.CropRequest{}) ==
             Map.from_struct(%ImagePipe.Dialect.Imgproxy.CropRequest{})
  end

  test "Orientation copy carries identical fields and defaults" do
    assert Map.from_struct(%ImagePipe.Parser.Imgproxy.Orientation{}) ==
             Map.from_struct(%ImagePipe.Dialect.Imgproxy.Orientation{})
  end

  describe "Format copy" do
    test "parses every source format name the framework original does" do
      for name <- ~w(jxl webp avif jpeg jpg png best) do
        assert ImagePipe.Dialect.Imgproxy.Format.parse(name) ==
                 ImagePipe.Parser.Imgproxy.Format.parse(name)
      end
    end

    test "rejects an unknown format with the framework original's error" do
      assert ImagePipe.Dialect.Imgproxy.Format.parse("tiff") ==
               ImagePipe.Parser.Imgproxy.Format.parse("tiff")
    end
  end
end
