defmodule ImagePipe.Plan.OutputTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output

  test "the built-in offsets use 2.4 for every format and content class" do
    offsets = Output.default_quality_search_offsets()

    for format <- [:jpeg, :webp, :avif], class <- [:photo, :graphic] do
      assert Output.offset_for(offsets, format, class) == 2.4
    end
  end
end
