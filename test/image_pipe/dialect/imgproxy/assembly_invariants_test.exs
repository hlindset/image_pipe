defmodule ImagePipe.Dialect.Imgproxy.AssemblyInvariantsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Neutral-Plan STRUCTURAL invariants, owned by the dialect.
  #
  # The wire/differential suites already pin the PIXEL behavior of each of these
  # requests. These pin the structural facts a pixel comparison cannot see: which
  # product-neutral guide TERM a gravity maps to, how objw weights canonicalize,
  # and the fixed operation-module ORDER.
  #
  # `Assembly.operations/1` takes a `PipelineRequest.t()` and returns
  # `{:ok, [Operation.semantic_operation()]}`. The request is built the same way
  # the sibling dialect tests build it — `struct!` over the dialect
  # `PipelineRequest`, with sub-struct fields (effects/orientation/crop) supplied
  # as plain keyword lists and inflated per row.

  alias ImagePipe.Dialect.Imgproxy.Assembly
  alias ImagePipe.Plan.Operation

  @request ImagePipe.Dialect.Imgproxy.PipelineRequest

  @sub_structs %{
    effects: ImagePipe.Dialect.Imgproxy.Effects,
    orientation: ImagePipe.Dialect.Imgproxy.Orientation,
    crop: ImagePipe.Dialect.Imgproxy.CropRequest
  }

  defp operations(fields), do: Assembly.operations(build_request(fields))

  defp build_request(fields) do
    fields
    |> Enum.map(fn {key, value} -> {key, build_field(key, value)} end)
    |> then(&struct!(@request, &1))
  end

  defp build_field(key, value) when is_list(value) do
    case Map.fetch(@sub_structs, key) do
      {:ok, module} -> struct!(module, value)
      :error -> value
    end
  end

  defp build_field(_key, value), do: value

  # The guide a `g:…` gravity lowers to on the fill-resize path — the dialect's
  # own analogue of plan_builder_test's `objw_guide/1` helper.
  defp fill_guide(gravity) do
    assert {:ok, [%Operation.Resize{} = resize]} =
             operations(
               resizing_type: :fill,
               width: {:pixels, 100},
               height: {:pixels, 100},
               gravity: gravity
             )

    resize.guide
  end

  # The same gravity on the crop path — proves the two paths share the object /
  # objw guide derivation and cannot diverge.
  defp crop_guide(gravity) do
    assert {:ok, [%Operation.CropGuided{} = crop]} =
             operations(crop: [width: {:pixels, 100}, height: {:pixels, 100}, gravity: gravity])

    crop.guide
  end

  defp objw_guide(pairs), do: fill_guide({:objw, pairs})

  # ── 1: only product-neutral guide terms leave the assembler ──────────────

  describe "operations emit only product-neutral guide terms" do
    test "no dialect-private gravity term (:sm, {:obj, _}, {:objw, _}) leaks into a guide" do
      for {gravity, expected_guide} <- [
            {:sm, :smart},
            {{:obj, ["face"]}, {:detect, {["face"], %{}}}},
            {{:objw, [{"face", 2.0}]}, {:detect, {["face"], %{"face" => 2.0}}}}
          ] do
        assert {:ok, ops} =
                 operations(
                   resizing_type: :fill,
                   width: {:pixels, 100},
                   height: {:pixels, 100},
                   gravity: gravity
                 )

        guides =
          for operation <- ops,
              guide = Map.get(operation, :guide),
              not is_nil(guide),
              do: guide

        assert expected_guide in guides
        refute Enum.any?(guides, &match?({:obj, _}, &1))
        refute Enum.any?(guides, &match?({:objw, _}, &1))
        refute :sm in guides
      end
    end
  end

  # ── 2: objw weight-map canonicalization ──────────────────────────────────

  describe "objw canonicalization" do
    test "merges duplicate classes (later wins), drops class==default, then drops a unit default" do
      # all-baseline above 1 is carried; a class equal to it is dropped
      assert objw_guide([{"all", 3.0}, {"car", 3.0}]) == {:detect, {:all, %{default: 3.0}}}

      # all-baseline above 1 with a below-default class: both survive
      assert objw_guide([{"all", 3.0}, {"car", 1.0}]) ==
               {:detect, {:all, %{"car" => 1.0, default: 3.0}}}

      # duplicate class key: the later pair wins
      assert objw_guide([{"face", 2.0}, {"face", 3.0}]) ==
               {:detect, {["face"], %{"face" => 3.0}}}

      # uniform weights at the unit default canonicalize to an empty map
      assert objw_guide([{"all", 1.0}, {"face", 1.0}]) == {:detect, {:all, %{}}}

      # a lone class at the unit default drops, leaving obj-equivalent guide
      assert objw_guide([{"face", 1.0}]) == {:detect, {["face"], %{}}}
    end

    property "objw canonicalization is order-independent" do
      check all classes <-
                  uniq_list_of(
                    member_of(["face", "car", "dog", "person", "cat", "bus", "truck", "bird"]),
                    min_length: 1,
                    max_length: 3
                  ),
                weights <- list_of(member_of([1.0, 2.0, 3.0]), length: length(classes)),
                default <- member_of([1.0, 2.0, 3.0]) do
        pairs = [{"all", default} | Enum.zip(classes, weights)]
        assert objw_guide(pairs) == objw_guide(Enum.shuffle(pairs))
      end
    end

    property "objw canonicalization is idempotent with all-broadened spec (re-feeding canonical map)" do
      check all classes <-
                  uniq_list_of(
                    member_of(["face", "car", "dog", "person", "cat", "bus", "truck", "bird"]),
                    min_length: 1,
                    max_length: 3
                  ),
                weights <- list_of(member_of([1.0, 2.0]), length: length(classes)),
                default <- member_of([1.0, 2.0]) do
        # Always include "all" so spec stays :all throughout the round-trip.
        pairs = [{"all", default} | Enum.zip(classes, weights)]
        {:detect, {:all, map}} = objw_guide(pairs)

        # Rebuild pairs from the canonical map (default → "all") and re-canonicalize.
        repairs =
          [
            {"all", Map.get(map, :default, 1.0)}
            | Enum.map(map, fn
                {:default, _w} -> nil
                {class, w} -> {class, w}
              end)
          ]
          |> Enum.reject(&is_nil/1)

        assert objw_guide(repairs) == {:detect, {:all, map}}
      end
    end
  end

  # ── 3: smart / face-assist / detect guide mapping ────────────────────────

  describe "smart / face-assist / detect guide mapping" do
    test "g:sm maps to :smart, and to {:smart, :face_assist} only with smart_crop_face_detection" do
      assert fill_guide(:sm) == :smart

      assert {:ok, [%Operation.Resize{guide: {:smart, :face_assist}}]} =
               operations(
                 resizing_type: :fill,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: :sm,
                 smart_crop_face_detection: true
               )

      assert {:ok, [%Operation.Resize{guide: :smart}]} =
               operations(
                 resizing_type: :fill,
                 width: {:pixels, 100},
                 height: {:pixels, 100},
                 gravity: :sm,
                 smart_crop_face_detection: false
               )
    end

    test "g:obj:CLASSES maps to a neutral detect guide (spec = classes, or :all)" do
      for {classes, spec} <- [
            {["face"], ["face"]},
            {["face", "cat"], ["face", "cat"]},
            {[], :all},
            {["all"], :all},
            {["car", "all"], :all}
          ] do
        assert fill_guide({:obj, classes}) == {:detect, {spec, %{}}}
      end
    end

    test "g:objw:… maps to a detect guide whose spec is the class list (filter, like obj)" do
      # named classes form the detection spec; weights carry the values
      assert objw_guide([{"person", 2.0}, {"face", 3.0}]) ==
               {:detect, {["person", "face"], %{"person" => 2.0, "face" => 3.0}}}

      # "all" broadens the spec to :all
      assert objw_guide([{"all", 1.0}, {"face", 3.0}]) == {:detect, {:all, %{"face" => 3.0}}}

      # objw:face:3 (filter) and objw:all:1:face:3 (:all) are NOT equivalent
      refute objw_guide([{"face", 3.0}]) == objw_guide([{"all", 1.0}, {"face", 3.0}])
    end

    test "the object/objw guide derivation is shared by the fill and crop paths" do
      for gravity <- [
            {:obj, ["face"]},
            {:obj, ["all"]},
            {:objw, [{"all", 2.0}, {"face", 3.0}]}
          ] do
        assert crop_guide(gravity) == fill_guide(gravity)
      end

      assert crop_guide({:objw, [{"all", 2.0}, {"face", 3.0}]}) ==
               {:detect, {:all, %{"face" => 3.0, default: 2.0}}}
    end
  end

  # ── 4: fixed operation order ─────────────────────────────────────────────

  describe "operation order is fixed regardless of URL option order" do
    test "a request touching every stage emits them in the fixed pipeline order" do
      assert {:ok, ops} =
               operations(
                 trim: [threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false],
                 orientation: [rotate: 90, flip: :vertical],
                 crop: [width: {:pixels, 400}, height: {:pixels, 300}],
                 width: {:pixels, 200},
                 height: {:pixels, 150},
                 resizing_type: :force,
                 enlarge: false,
                 dpr: 2.0,
                 effects: [blur: 2.0, saturation: 0.5],
                 extend: true,
                 extend_aspect_ratio: true,
                 padding_top: 10,
                 background_color: color!(1, 2, 3)
               )

      assert [
               %Operation.Trim{},
               %Operation.Rotate{},
               %Operation.Flip{},
               %Operation.CropGuided{},
               %Operation.Resize{},
               %Operation.Blur{},
               %Operation.Saturation{},
               %Operation.Canvas{},
               %Operation.Canvas{},
               %Operation.Padding{},
               %Operation.Background{}
             ] = ops
    end
  end

  # ── 5: mw:0/mh:0 is "no minimum on that axis", distinct from unset ────────

  describe "min-dimension zero sentinel" do
    test "mw:0/mh:0 mean no minimum on that axis (:auto), distinct from unset (nil)" do
      assert {:ok, [%Operation.Resize{min_width: :auto, min_height: :auto}]} =
               operations(
                 width: {:pixels, 800},
                 min_width: {:pixels, 0},
                 min_height: {:pixels, 0}
               )

      assert {:ok, [%Operation.Resize{min_width: nil, min_height: nil}]} =
               operations(width: {:pixels, 800})
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  defp color!(red, green, blue) do
    {:ok, color} = Operation.color(red, green, blue)
    color
  end
end
