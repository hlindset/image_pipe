defmodule Mix.Tasks.Fixtures.GenSourcesTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Fixtures.GenSources

  test "chirp_pixels/2 is deterministic and the right size (3 bands, uchar)" do
    a = GenSources.chirp_pixels(32, 24)
    b = GenSources.chirp_pixels(32, 24)
    assert a == b
    assert byte_size(a) == 32 * 24 * 3
  end

  test "chirp_pixels/2 varies spatially (not a flat image)" do
    bin = GenSources.chirp_pixels(64, 64)
    assert byte_size(bin) == 64 * 64 * 3
    refute bin == :binary.copy(<<:binary.at(bin, 0)>>, byte_size(bin))
  end
end
