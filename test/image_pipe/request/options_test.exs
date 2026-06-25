defmodule ImagePipe.Request.OptionsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Request.Options

  test "allow_debug_headers defaults to false" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy)
    assert Keyword.fetch!(opts, :allow_debug_headers) == false
  end

  test "allow_debug_headers can be enabled" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_debug_headers: true)
    assert Keyword.fetch!(opts, :allow_debug_headers) == true
  end

  test "allow_debug_headers rejects non-boolean" do
    assert_raise ArgumentError, fn ->
      Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_debug_headers: "yes")
    end
  end
end
