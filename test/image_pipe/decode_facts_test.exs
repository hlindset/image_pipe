defmodule ImagePipe.DecodeFactsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.SourceGeometry
  alias ImgproxyWireConformanceTest.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  test "with_image geometry carries the six source debug facts" do
    # validate_runtime! converts :sources into the map Source.resolve expects
    # and supplies the max_body_bytes/max_input_pixels defaults decode reads.
    config = SharedConfig.validate_runtime!(sources: @sources)
    source = %Path{segments: ["images", "beach.jpg"]}
    {:ok, resolved} = Source.resolve(source, config, config)

    result =
      Decode.with_image(
        resolved,
        Keyword.put(config, :auto_rotate?, true),
        fn _geometry -> %DecodePlanner.Request{} end,
        fn _state, %SourceGeometry{debug_facts: facts} -> {:ok, facts} end
      )

    assert {:ok, facts} = result
    assert is_integer(facts.source_bytes) and facts.source_bytes > 0
    assert is_atom(facts.source_color_space)
    assert is_boolean(facts.source_icc?)
    assert facts.source_bit_depth in [8, 16]
    assert is_boolean(facts.source_alpha?)
    assert facts.source_orientation in [nil, 1, 2, 3, 4, 5, 6, 7, 8]
  end
end
