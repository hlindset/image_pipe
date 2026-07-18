defmodule ImagePipe.Dialect.TwicPics.ManipulationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Manipulation

  test "splits an ordered v1 chain into name/args segments" do
    assert Manipulation.parse("v1/focus=top/cover=100x100/output=avif") ==
             {:ok, [{"focus", "top"}, {"cover", "100x100"}, {"output", "avif"}]}
  end

  test "requires the v1 prefix" do
    assert {:error, {:unsupported_manipulation_version, _}} = Manipulation.parse("v2/resize=10")
    assert {:error, {:unsupported_manipulation_version, _}} = Manipulation.parse("resize=10")
  end

  test "rejects a segment without =" do
    assert {:error, {:invalid_segment, "resize"}} = Manipulation.parse("v1/resize")
  end

  test "ignores empty segments from stray slashes" do
    assert {:ok, [{"resize", "10"}]} = Manipulation.parse("v1/resize=10/")
  end

  test "does not split on a `/` inside a parenthesized expression (#325)" do
    assert Manipulation.parse("v1/resize=(700/2)/output=png") ==
             {:ok, [{"resize", "(700/2)"}, {"output", "png"}]}

    assert Manipulation.parse("v1/crop=(100/(4/2))x50/output=png") ==
             {:ok, [{"crop", "(100/(4/2))x50"}, {"output", "png"}]}
  end
end
