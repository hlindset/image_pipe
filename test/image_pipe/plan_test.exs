defmodule ImagePipe.PlanTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  test "validated pipelines accept semantic operation structs" do
    operation = resize_operation()

    plan = %Plan{
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: [operation]}],
      output: %Output{mode: {:explicit, :webp}}
    }

    assert {:ok, [%Pipeline{operations: [^operation]}]} = Plan.validated_pipelines(plan)
  end

  test "validated pipelines accept semantic orientation operations" do
    operations = [%Rotate{angle: 90}, %Flip{axis: :horizontal}]

    plan =
      plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok, [%Pipeline{operations: ^operations}]} = Plan.validated_pipelines(plan)
  end

  test "validate shape accepts default product-neutral facets" do
    plan = plan()

    assert {:ok, ^plan} = Plan.validate_shape(plan)
  end

  test "validate shape rejects improper path source without raising" do
    for source <- [
          %Source.Path{segments: []},
          %Source.Path{segments: ["images" | :bad]}
        ] do
      assert Plan.validate_shape(plan(source: source)) ==
               {:error, {:unsupported_source, source}}
    end
  end

  test "validate shape rejects invalid expires values" do
    for expires <- [-1, 1.5, "60", nil] do
      assert Plan.validate_shape(plan(expires: expires)) ==
               {:error, {:invalid_expires, expires}}
    end
  end

  test "validate shape rejects invalid cachebuster values" do
    for cachebuster <- [:v1, 1, []] do
      assert Plan.validate_shape(plan(cachebuster: cachebuster)) ==
               {:error, {:invalid_cachebuster, cachebuster}}
    end
  end

  test "validate shape rejects invalid response disposition values" do
    for disposition <- [:download, "attachment", nil] do
      response = %Response{disposition: disposition}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "validate shape rejects invalid response filename values" do
    for filename <- [:cat, 1, []] do
      response = %Response{filename: filename}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "validate shape rejects malformed response filename strings" do
    for filename <- [
          "",
          <<255>>,
          1,
          "a/b",
          "a\\b",
          "a\nb"
        ] do
      response = %Response{filename: filename}

      assert Plan.validate_shape(plan(response: response)) ==
               {:error, {:invalid_response_plan, response}}
    end
  end

  test "detect_classes finds a {:detect, classes} guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["face"], %{}}})) == ["face"]
  end

  test "detect_classes returns a guide's classes sorted and deduped" do
    assert Plan.detect_classes(plan_with_guide({:detect, {["dog", "car", "dog"], %{}}})) == [
             "car",
             "dog"
           ]
  end

  test "detect_classes returns :all for an all-objects guide" do
    assert Plan.detect_classes(plan_with_guide({:detect, {:all, %{}}})) == :all
  end

  test "detect_classes is nil when no detect guide is present" do
    assert Plan.detect_classes(plan_with_guide(:center)) == nil
  end

  test "detect_classes is nil for an operation without a guide field" do
    plan = plan(pipelines: [%Pipeline{operations: [%Rotate{angle: 90}]}])
    assert Plan.detect_classes(plan) == nil
  end

  test "face_assist? detects a {:smart, :face_assist} guide" do
    assert Plan.face_assist?(plan_with_guide({:smart, :face_assist}))
  end

  test "face_assist? is false otherwise" do
    refute Plan.face_assist?(plan_with_guide(:smart))
  end

  test "auto_rotate defaults to false and validate_shape accepts booleans" do
    plan = plan()

    assert plan.auto_rotate == false
    assert {:ok, _} = Plan.validate_shape(%{plan | auto_rotate: true})
    assert {:error, {:invalid_auto_rotate, _}} = Plan.validate_shape(%{plan | auto_rotate: "yes"})
  end

  test "validate_shape accepts recognized encoder_options structs and rejects malformed maps" do
    plan = plan()

    good = %{
      plan.output
      | encoder_options: %{jpeg: %ImagePipe.Plan.Output.JpegOptions{interlace: true}}
    }

    assert {:ok, _} = Plan.validate_shape(%{plan | output: good})

    # a bare map (not a recognized struct) must be rejected at the boundary
    bad = %{plan.output | encoder_options: %{jpeg: %{lossless: true}}}
    assert {:error, {:invalid_output_plan, _}} = Plan.validate_shape(%{plan | output: bad})

    # struct under the wrong format key is rejected too
    mismatched = %{plan.output | encoder_options: %{png: %ImagePipe.Plan.Output.JpegOptions{}}}
    assert {:error, {:invalid_output_plan, _}} = Plan.validate_shape(%{plan | output: mismatched})

    # an unknown format key (even with a real struct) is rejected
    unknown = %{plan.output | encoder_options: %{bogus: %ImagePipe.Plan.Output.JpegOptions{}}}
    assert {:error, {:invalid_output_plan, _}} = Plan.validate_shape(%{plan | output: unknown})
  end

  describe "validate_shape strategy-requiring vocabulary" do
    test "rejects a :deferred resize guide without a resolver" do
      assert {:ok, operation} = Operation.resize(:cover, {:px, 100}, {:px, 100}, guide: :deferred)
      plan = plan(pipelines: [%Pipeline{operations: [operation]}])

      assert {:error, {:strategy_required, ^operation}} = Plan.validate_shape(plan)
      assert {:ok, _} = Plan.validate_shape(%{plan | resolver: SomeStrategy})
    end

    test "rejects a :deferred crop guide without a resolver" do
      assert {:ok, operation} = Operation.crop_guided({:px, 100}, :full_axis, :deferred)
      plan = plan(pipelines: [%Pipeline{operations: [operation]}])

      assert {:error, {:strategy_required, ^operation}} = Plan.validate_shape(plan)
      assert {:ok, _} = Plan.validate_shape(%{plan | resolver: SomeStrategy})
    end

    test "rejects a directive without a resolver" do
      assert {:ok, operation} = Operation.directive(:set_focus, {:anchor, :center, :center})
      plan = plan(pipelines: [%Pipeline{operations: [operation]}])

      assert {:error, {:strategy_required, ^operation}} = Plan.validate_shape(plan)
      assert {:ok, _} = Plan.validate_shape(%{plan | resolver: SomeStrategy})
    end

    test "rejects an :auto resize mode without a resolver" do
      assert {:ok, operation} = Operation.resize(:auto, {:px, 100}, {:px, 50})
      plan = plan(pipelines: [%Pipeline{operations: [operation]}])

      assert {:error, {:strategy_required, ^operation}} = Plan.validate_shape(plan)
      assert {:ok, _} = Plan.validate_shape(%{plan | resolver: SomeStrategy})
    end

    test "rejects an {:effective, …} padding scale without a resolver" do
      assert {:ok, operation} =
               Operation.padding({:px, 4}, {:px, 4}, {:px, 4}, {:px, 4},
                 pixel_ratio: {:effective, {:ratio, 2, 1}, :resize}
               )

      plan = plan(pipelines: [%Pipeline{operations: [operation]}])

      assert {:error, {:strategy_required, ^operation}} = Plan.validate_shape(plan)
      assert {:ok, _} = Plan.validate_shape(%{plan | resolver: SomeStrategy})
    end

    test "accepts neutral-resolvable guides without a resolver" do
      assert {:ok, smart} = Operation.crop_guided({:px, 100}, :full_axis, :smart)

      assert {:ok, detect} =
               Operation.crop_guided({:px, 100}, :full_axis, {:detect, {:all, %{}}})

      assert {:ok, _} = Plan.validate_shape(plan(pipelines: [%Pipeline{operations: [smart]}]))
      assert {:ok, _} = Plan.validate_shape(plan(pipelines: [%Pipeline{operations: [detect]}]))
    end
  end

  test "validate_shape rejects a non-module resolver" do
    plan = %{plan() | resolver: "imgproxy"}
    assert {:error, {:invalid_resolver_plan, "imgproxy"}} = Plan.validate_shape(plan)
  end

  test "validate_shape accepts a nil and a module resolver" do
    assert {:ok, _} = Plan.validate_shape(plan())

    assert {:ok, _} =
             Plan.validate_shape(%{plan() | resolver: ImagePipe.Transform.NeutralResolver})
  end

  describe "operation_names/1" do
    test "returns stable operation-name atoms in order across pipelines" do
      {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto, enlargement: :deny)

      plan =
        plan(
          pipelines: [
            %Pipeline{operations: [resize, %Flip{axis: :horizontal}]}
          ]
        )

      assert Plan.operation_names(plan) == [:resize, :flip]
    end

    test "flattens multiple pipelines in order and derives underscore names" do
      {:ok, resize} = Operation.resize(:fit, {:px, 100}, :auto, enlargement: :deny)
      {:ok, crop_guided} = Operation.crop_guided({:px, 50}, {:px, 50}, :center)

      plan =
        plan(
          pipelines: [
            %Pipeline{operations: [resize, %Flip{axis: :horizontal}]},
            %Pipeline{operations: [crop_guided]}
          ]
        )

      assert Plan.operation_names(plan) == [:resize, :flip, :crop_guided]
    end
  end

  defp plan_with_guide(guide) do
    operation = %CropGuided{width: {:px, 10}, height: {:px, 10}, guide: guide}
    plan(pipelines: [%Pipeline{operations: [operation]}])
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %Source.Path{segments: ["images", "cat.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: :automatic}
        ],
        overrides
      )
    )
  end

  defp resize_operation do
    assert {:ok, operation} = Operation.resize(:fit, {:px, 300}, :auto, enlargement: :deny)
    operation
  end
end
