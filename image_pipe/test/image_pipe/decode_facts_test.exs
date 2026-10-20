defmodule ImagePipe.DecodeFactsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.Decode
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plug.Config
  alias ImagePipe.Source
  alias ImagePipe.Source.Path
  alias ImagePipe.Transform.SourceGeometry

  @sources [
    path: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "priv/static/images", root_id: "decode-facts"]
    ]
  ]

  test "with_image geometry carries the source debug facts" do
    assert {:ok, facts} = facts("beach.jpg")
    assert is_integer(facts.source_bytes) and facts.source_bytes > 0
    assert is_atom(facts.source_color_space)
    assert is_boolean(facts.source_icc?)
    assert facts.source_bit_depth in [8, 16]
    assert is_boolean(facts.source_alpha?)
    assert facts.source_orientation in [nil, 1, 2, 3, 4, 5, 6, 7, 8]
  end

  test "source_progressive? is set for JPEG only" do
    assert {:ok, %{source_progressive?: true}} = facts("beach.jpg")
    assert {:ok, %{source_progressive?: false}} = facts("woman.jpg")
    assert {:ok, %{source_progressive?: nil}} = facts("cooking.png")
  end

  defp facts(name) do
    config = Config.validate!(sources: @sources)
    source = %Path{segments: [name]}
    {:ok, resolved} = Source.resolve(source, config, config)
    source_value = name

    assert {:ok, %Spec{} = request} =
             Parser.parse(
               %{segments: [], source: {:src, source_value, {0, byte_size(source_value)}}},
               config
             )

    Decode.with_image(
      resolved,
      request,
      config,
      fn _state, %SourceGeometry{debug_facts: facts} -> {:ok, facts} end
    )
  end
end
