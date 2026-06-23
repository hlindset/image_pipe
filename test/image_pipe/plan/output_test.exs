defmodule ImagePipe.Plan.OutputTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output

  test "defaults quality_search to :none and max_bytes to nil" do
    o = %Output{mode: :automatic}
    assert o.quality_search == :none
    assert o.max_bytes == nil
  end

  test "default quality_search_offsets carries the 2.4 default and the avif×graphic override" do
    %Output{quality_search_offsets: offsets} = %Output{mode: :automatic}
    assert offsets.default == 2.4
    assert Map.fetch!(offsets.overrides, {:avif, :graphic}) == 6.0
  end

  test "offset_for/3 falls back to the default for unlisted cells" do
    offsets = Output.default_quality_search_offsets()
    assert Output.offset_for(offsets, :avif, :graphic) == 6.0
    assert Output.offset_for(offsets, :avif, :photo) == 2.4
    assert Output.offset_for(offsets, :jpeg, :graphic) == 2.4
    assert Output.offset_for(offsets, :webp, :photo) == 2.4
  end
end
