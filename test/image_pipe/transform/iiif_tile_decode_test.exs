defmodule ImagePipe.Transform.IIIFTileDecodeTest do
  @moduledoc """
  Verifies a IIIF tile request (region crop + downscale) engages shrink-on-load.
  DecodePlanner is the in-repo producer of the decode load options; we assert its
  actual output rather than inventing a telemetry hook.
  """
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.DecodePlanner

  test "tile region+downscale engages shrink-on-load" do
    # OSD tile at scale factor 8 against a 6000x4000 source: crop a 4096x4096
    # region, downscale to a 512x512 tile.
    {:ok, crop} = Operation.crop_region({:px, 0}, {:px, 0}, {:px, 4096}, {:px, 4096})
    {:ok, resize} = Operation.resize(:stretch, {:px, 512}, {:px, 512})

    opts =
      [crop, resize]
      |> DecodePlanner.request_from_chain({6000, 4000}, false)
      |> DecodePlanner.open_options_for(:jpeg, {6000, 4000})

    assert Keyword.get(opts, :access) == :sequential
    # Shrink-on-load fires for the crop-then-downscale tile shape: the source is
    # decoded at 1/4 resolution rather than full-res. (Observed factor: 4.)
    assert Keyword.get(opts, :shrink) == 4
  end
end
