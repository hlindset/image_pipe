defmodule ImagePipe.Dialect.TwicPics.OutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Output
  alias ImagePipe.Plan.Output, as: PlanOutput

  test "auto, explicit formats, and quality" do
    assert Output.build(%{format: :auto, quality: :default}) ==
             {:ok, %PlanOutput{mode: :automatic, quality: :default}}

    assert Output.build(%{format: :avif, quality: {:quality, 80}}) ==
             {:ok, %PlanOutput{mode: {:explicit, :avif}, quality: {:quality, 80}}}
  end

  test "parse format and quality strings" do
    assert Output.format("auto") == {:ok, :auto}
    assert Output.format("webp") == {:ok, :webp}
    assert {:error, _} = Output.format("blurhash")
    assert Output.quality("80") == {:ok, {:quality, 80}}
    assert {:error, _} = Output.quality("0")
    assert {:error, _} = Output.quality("101")
  end
end
