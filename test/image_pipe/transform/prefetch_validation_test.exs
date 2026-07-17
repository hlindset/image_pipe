defmodule ImagePipe.Transform.PrefetchValidationTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source
  alias ImagePipe.Transform

  test "semantic Plan operations pass source-independent validation" do
    assert {:ok, operation} = Operation.resize(:auto, {:px, 100}, {:px, 100}, enlargement: :deny)

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "crop regions are prefetch-safe semantic operations" do
    operation = crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^operation]}]} =
             Transform.validate_prefetch_safe_plan(plan([operation]))
  end

  test "crop regions after prior geometry remain current-image-relative operations" do
    resize = resize_operation()
    crop = crop_region_operation()

    assert {:ok, [%Pipeline{operations: [^resize, ^crop]}]} =
             Transform.validate_prefetch_safe_plan(plan([resize, crop]))
  end

  test "semantic orientation operations pass source-independent validation" do
    operations = [%Rotate{angle: 90}, %Flip{axis: :horizontal}]

    assert {:ok, [%Pipeline{operations: ^operations}]} =
             Transform.validate_prefetch_safe_plan(plan(operations))
  end

  defp plan(operations) do
    %Plan{
      source: %Source.Path{segments: ["images", "cat.jpg"]},
      pipelines: [%Pipeline{operations: operations}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resize_operation do
    {:ok, operation} = Operation.resize(:fit, {:px, 100}, {:px, 100}, enlargement: :deny)
    operation
  end

  defp crop_region_operation do
    {:ok, operation} = Operation.crop_region({:px, 1}, {:px, 1}, {:px, 10}, {:px, 10})
    operation
  end
end
