defmodule ImagePipe.Dialect.TwicPics.RequestBuilderTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Path

  defp build(chain, config \\ []) do
    RequestBuilder.build(
      %Path{segments: ["x.jpg"]},
      chain,
      ImagePipe.Config.resolve!(config)
    )
  end

  test "legacy: resize single dim -> fit auto; WxH -> stretch" do
    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.Resize{mode: :fit, width: {:px, 100}, height: :auto}}
              ]
            }} = build([{"resize", "100"}])

    assert {:ok,
            %Request{
              steps: [
                {:operation,
                 %Operation.Resize{mode: :stretch, width: {:px, 100}, height: {:px, 50}}}
              ]
            }} = build([{"resize", "100x50"}])
  end

  test "legacy: a folded arithmetic length builds the same plan as its literal equivalent (#325)" do
    assert build([{"resize", "(100/2)"}]) == build([{"resize", "50"}])

    assert build([{"resize", "(700/2)x(300/3)"}]) ==
             build([{"resize", "350x100"}])
  end

  test "legacy: a fractional bare-pixel length rounds into the plan (#325)" do
    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.Resize{mode: :fit, width: {:px, 4}, height: :auto}}
              ]
            }} = build([{"resize", "(7/2)"}])
  end

  test "legacy: relative-unit resize is emitted as one op per segment (no static collapse)" do
    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.Resize{width: {:px, 340}}},
                {:operation, %Operation.Resize{width: {:ratio, 1, 2}}}
              ]
            }} = build([{"resize", "340"}, {"resize", "50p"}])
  end

  test "quarantined relative resize shadow chain remains two literal ordered steps" do
    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.Resize{width: {:ratio, 1, 2}}},
                {:operation, %Operation.Resize{width: {:px, 340}}}
              ]
            }} = build([{"resize", "50p"}, {"resize", "340"}])
  end

  test "legacy: focus anchor emits a positional set_focus directive and a carried cover (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:anchor, :center, :top}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "top"}, {"cover", "100x100"}])
  end

  test "legacy: relative-unit coordinate focus emits set_focus directive + carried cover (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:coord, {:ratio, 1, 4}, {:ratio, 3, 4}}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "25px75p"}, {"cover", "100x100"}])
  end

  test "legacy: bare-pixel coordinate focus emits set_focus directive + carried cover (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:coord, {:px, 20}, {:px, 10}}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "20x10"}, {"cover", "100x100"}])
  end

  test "legacy: mixed-unit coordinate focus (100x50p) parses to px + relative (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:coord, {:px, 100}, {:ratio, 1, 2}}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "100x50p"}, {"cover", "100x100"}])
  end

  test "legacy: relative focus > 1 is clamped at execution, not rejected at the parser (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:coord, {:ratio, 3, 2}, {:ratio, 3, 2}}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "150px150p"}, {"cover", "100x100"}])
  end

  test "legacy: an edge focal ratio of exactly 1 (100p) emits a set_focus directive (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:coord, {:ratio, 1, 1}, {:ratio, 0, 1}}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "100px0p"}, {"cover", "100x100"}])
  end

  test "legacy: focus=auto -> face-assist smart guide on the next cover" do
    assert {:ok,
            %Request{
              steps: [
                :set_auto_focus,
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "auto"}, {"cover", "100x100"}])
  end

  test "legacy: focus=auto -> face-assist smart guide on the next guided crop" do
    assert {:ok,
            %Request{
              steps: [
                :set_auto_focus,
                {:focused, %Operation.CropGuided{guide: :center}}
              ]
            }} = build([{"focus", "auto"}, {"crop", "100x100"}])
  end

  test "legacy: negative focus is rejected before any fetch (#321)" do
    assert {:error, {:unsupported_focus, "-50x-50"}} = build([{"focus", "-50x-50"}])
  end

  test "legacy: focus=center emits a centre set_focus directive (live TwicPics accepts it)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:anchor, :center, :center}},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"focus", "center"}, {"cover", "100x100"}])
  end

  test "legacy: cover ratio -> guided ratio crop" do
    assert {:ok,
            %Request{
              steps: [
                {:focused,
                 %Operation.CropGuided{
                   width: :full_axis,
                   height: :full_axis,
                   guide: :center,
                   aspect_ratio: {:ratio, 16, 9}
                 }}
              ]
            }} = build([{"cover", "16:9"}])
  end

  test "legacy: cover decimal ratio reduces and flows into the guided crop" do
    assert {:ok,
            %Request{
              steps: [
                {:focused, %Operation.CropGuided{guide: :center, aspect_ratio: {:ratio, 3, 4}}}
              ]
            }} = build([{"cover", "1.5:2"}])
  end

  test "legacy: inside -> fit resize plus transparent canvas" do
    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.Resize{mode: :fit}},
                {:operation, %Operation.Canvas{fill: :transparent}}
              ]
            }} = build([{"inside", "100x80"}])
  end

  test "legacy: inside ratio -> single pad-to-ratio transparent canvas" do
    assert {:ok,
            %Request{
              steps: [
                {:operation,
                 %Operation.Canvas{
                   width: {:ratio, 4, 1},
                   height: {:ratio, 3, 1},
                   placement: :center,
                   fill: :transparent
                 }}
              ]
            }} = build([{"inside", "4:3"}])
  end

  test "legacy: crop without coords carries the focus; with coords emits CropRegion (#321)" do
    assert {:ok,
            %Request{
              steps: [
                {:set_focus, {:anchor, :center, :top}},
                {:focused, %Operation.CropGuided{guide: :center}}
              ]
            }} = build([{"focus", "top"}, {"crop", "100x100"}])

    assert {:ok,
            %Request{
              steps: [
                {:operation,
                 %Operation.CropRegion{
                   x: {:px, 20},
                   y: {:px, 50},
                   width: {:px, 100},
                   height: {:px, 100}
                 }},
                {:focused, %Operation.Resize{mode: :cover, guide: :center}}
              ]
            }} = build([{"crop", "100x100@20x50"}, {"cover", "10x10"}])
  end

  test "legacy: output/quality last-wins, applied to Output not the pipeline" do
    assert {:ok,
            %Request{
              steps: [{:operation, %Operation.Resize{width: {:px, 10}}}],
              output: %Output{
                mode: {:explicit, :webp},
                quality: {:quality, 70},
                strip_metadata: false
              },
              response: %Response{debug?: true}
            }} =
             build(
               [
                 {"resize", "10"},
                 {"output", "avif"},
                 {"debug", "0"},
                 {"output", "webp"},
                 {"quality", "80"},
                 {"quality", "70"},
                 {"debug", "1"}
               ],
               strip_metadata: false
             )
  end

  test "legacy: rejected non-goals fail the whole build" do
    assert {:error, {:unsupported_transform, "zoom"}} = build([{"zoom", "2"}])

    assert {:error, {:unsupported_transform_ratio, "resize"}} =
             build([{"resize", "16:9"}])

    assert {:error, {:unsupported_focus, "middle"}} = build([{"focus", "middle"}])
  end

  test "legacy: relative units on inside are rejected (pixel-only)" do
    assert {:error, {:unsupported_unit, :inside}} = build([{"inside", "50p"}])
  end

  test "legacy: relative crop dimensions and zero-based coordinates build a plan" do
    assert {:ok,
            %Request{
              steps: [
                {:focused,
                 %Operation.CropGuided{
                   width: {:ratio, 1, 2},
                   height: {:ratio, 1, 2},
                   guide: :center
                 }}
              ]
            }} = build([{"crop", "50px50p"}])

    assert {:ok,
            %Request{
              steps: [
                {:operation,
                 %Operation.CropRegion{
                   x: {:ratio, 1, 4},
                   y: {:ratio, 1, 2},
                   width: {:px, 200},
                   height: {:px, 200}
                 }}
              ]
            }} = build([{"crop", "200x200@0.25sx0.5s"}])

    assert {:ok,
            %Request{
              steps: [
                {:operation, %Operation.CropRegion{x: {:px, 0}, y: {:px, 0}}}
              ]
            }} = build([{"crop", "100x100@0x0"}])
  end

  test "legacy: a region crop requires both axes explicit (omitted axis is rejected)" do
    assert {:error, {:unsupported_crop_region_size, "100"}} =
             build([{"crop", "100@20x50"}])
  end

  test "legacy: an empty pipeline still produces a valid no-op plan when only output is set" do
    assert {:ok,
            %Request{
              source: %Path{segments: ["x.jpg"]},
              steps: [],
              output: %Output{mode: :automatic},
              response: %Response{debug?: false},
              auto_rotate: true
            }} = build([{"output", "auto"}])
  end

  test "every produced request recursively excludes plan and runtime vocabulary" do
    chains = [
      [],
      [{"resize", "200"}, {"resize", "50p"}],
      [{"focus", "top"}, {"cover", "100x100"}],
      [{"focus", "auto"}, {"crop", "50px50p"}],
      [{"crop", "100x100@0x0"}],
      [{"inside", "4:3"}],
      [{"inside", "100x80"}],
      [{"contain", "200x100"}],
      [{"output", "webp"}, {"quality", "72"}, {"debug", "1"}]
    ]

    Enum.each(chains, fn chain ->
      assert {:ok, %Request{} = request} = build(chain)
      assert forbidden_terms(request) == []
    end)
  end

  test "forbidden-vocabulary scan is recursive and recognizes every rejected shape" do
    plan = %ImagePipe.Plan{
      source: %Path{segments: ["x.jpg"]},
      pipelines: [],
      output: %Output{mode: :automatic}
    }

    assert match?([{:plan, _}], forbidden_terms(%{nested: [plan]}))
    assert forbidden_terms(%{nested: [ImagePipe.Plan]}) == [{:plan, ImagePipe.Plan}]
    assert match?([{:raw_pair, _}], forbidden_terms(%{nested: [{"resize", "40x30"}]}))
    assert match?([{:conn, _}], forbidden_terms(%{nested: [%Plug.Conn{}]}))
    assert match?([{:pid, _}], forbidden_terms(%{nested: [self()]}))
    assert match?([{:reference, _}], forbidden_terms(%{nested: [make_ref()]}))
  end

  test "absolute coordinate focus retains its running-frame position around resize" do
    assert {:ok, %Request{} = resize_before_focus} =
             build([{"resize", "50p"}, {"focus", "50x50"}, {"crop", "40x40"}])

    assert {:ok, %Request{} = focus_before_resize} =
             build([{"focus", "50x50"}, {"resize", "50p"}, {"crop", "40x40"}])

    refute resize_before_focus == focus_before_resize

    assert %Request{
             steps: [
               {:operation, %Operation.Resize{mode: :fit, width: {:ratio, 1, 2}}},
               {:set_focus, {:coord, {:px, 50}, {:px, 50}}},
               {:focused,
                %Operation.CropGuided{
                  width: {:px, 40},
                  height: {:px, 40},
                  guide: :center
                }}
             ]
           } = resize_before_focus

    assert %Request{
             steps: [
               {:set_focus, {:coord, {:px, 50}, {:px, 50}}},
               {:operation, %Operation.Resize{mode: :fit, width: {:ratio, 1, 2}}},
               {:focused,
                %Operation.CropGuided{
                  width: {:px, 40},
                  height: {:px, 40},
                  guide: :center
                }}
             ]
           } = focus_before_resize
  end

  defp forbidden_terms(term), do: do_forbidden_terms(term, [])

  defp do_forbidden_terms(%Plug.Conn{} = conn, violations),
    do: [{:conn, conn} | violations]

  defp do_forbidden_terms(%ImagePipe.Plan{} = plan, violations),
    do: [{:plan, plan} | violations]

  defp do_forbidden_terms(term, violations) when is_pid(term),
    do: [{:pid, term} | violations]

  defp do_forbidden_terms(term, violations) when is_reference(term),
    do: [{:reference, term} | violations]

  defp do_forbidden_terms(ImagePipe.Plan, violations), do: [{:plan, ImagePipe.Plan} | violations]

  defp do_forbidden_terms(module, violations) when is_atom(module) do
    case module |> Atom.to_string() |> String.contains?("Resolver") do
      true -> [{:resolver, module} | violations]
      false -> violations
    end
  end

  defp do_forbidden_terms({name, args} = pair, violations)
       when is_binary(name) and is_binary(args),
       do: [{:raw_pair, pair} | violations]

  defp do_forbidden_terms(%_{} = struct, violations),
    do: do_forbidden_terms(Map.from_struct(struct), violations)

  defp do_forbidden_terms(map, violations) when is_map(map) do
    Enum.reduce(map, violations, fn {key, value}, acc ->
      do_forbidden_terms(value, do_forbidden_terms(key, acc))
    end)
  end

  defp do_forbidden_terms(list, violations) when is_list(list),
    do: Enum.reduce(list, violations, &do_forbidden_terms/2)

  defp do_forbidden_terms(tuple, violations) when is_tuple(tuple) do
    tuple
    |> Tuple.to_list()
    |> Enum.reduce(violations, &do_forbidden_terms/2)
  end

  defp do_forbidden_terms(_term, violations), do: violations
end
