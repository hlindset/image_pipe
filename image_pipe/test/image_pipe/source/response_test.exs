defmodule ImagePipe.Source.ResponseTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.Response

  test "constructs without enforcing a stream and defaults both fields to nil" do
    assert %Response{} == %Response{stream: nil, path: nil}
  end
end
