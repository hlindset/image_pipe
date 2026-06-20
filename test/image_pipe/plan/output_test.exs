defmodule ImagePipe.Plan.OutputTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output

  test "defaults quality_search to :none and max_bytes to nil" do
    o = %Output{mode: :automatic}
    assert o.quality_search == :none
    assert o.max_bytes == nil
  end
end
