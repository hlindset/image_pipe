defmodule ImagePipe.Debug.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Debug.Info

  test "defaults: empty pipeline, empty timings, nil autoquality" do
    info = %Info{}

    assert info.pipeline == []
    assert info.timings == %{}
    assert info.aq == nil
    assert info.source_format == nil
    assert info.output_format == nil
  end

  test "holds source, output, autoquality, pipeline, and timing facts" do
    info = %Info{
      source_format: :jpeg,
      source_width: 4000,
      source_height: 3000,
      output_format: :avif,
      output_width: 1200,
      output_height: 900,
      output_quality: 72,
      aq: %{metric: :ssimulacra2, score: 78.4, min: 60, max: 65},
      pipeline: ["scale", "crop"],
      timings: %{decode: 8, transform: 21, encode: 140, total: 181}
    }

    assert info.source_format == :jpeg
    assert info.aq.metric == :ssimulacra2
    assert info.pipeline == ["scale", "crop"]
    assert info.timings.total == 181
  end
end
