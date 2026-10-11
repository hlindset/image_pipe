defmodule ImagePipe.SVGTest do
  use ExUnit.Case, async: true

  test "reports the NIF version and the resvg version from Cargo.lock" do
    lock = File.read!("native/image_pipe_svg_nif/Cargo.lock")
    [_, resvg] = Regex.run(~r/name = "resvg"\nversion = "([^"]+)"/, lock)

    assert ImagePipe.SVG.versions() == %{
             nif: Mix.Project.config()[:version],
             resvg: resvg
           }
  end
end
