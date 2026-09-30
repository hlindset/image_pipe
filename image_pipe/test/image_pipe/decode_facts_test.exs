defmodule ImagePipe.DecodeFactsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.Decode
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plug.Config
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.OriginImage
  alias ImagePipe.Transform.SourceGeometry

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  test "with_image geometry carries the six source debug facts" do
    config = Config.validate!(sources: @sources)
    source = %Path{segments: ["images", "beach.jpg"]}
    {:ok, resolved} = Source.resolve(source, config, config)
    source_value = "images/beach.jpg"

    assert {:ok, %Request{} = request} =
             Parser.parse(
               %{segments: [], source: {:src, source_value, {0, byte_size(source_value)}}},
               config
             )

    result =
      Decode.with_image(
        resolved,
        request,
        config,
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
