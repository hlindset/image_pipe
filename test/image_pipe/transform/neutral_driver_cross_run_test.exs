defmodule ImagePipe.Transform.NeutralDriverCrossRunTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.NeutralResolver
  alias ImagePipe.Transform.Operation.Blur
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.Operation.Rotate
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceShape
  alias ImagePipe.Transform.State

  describe "run_neutral/4" do
    test "matches the injected neutral strategy across neutral operation and boundary classes" do
      cases = [
        %{
          name: "identity effect",
          operations: [operation!(:blur, [1.0])],
          pending_orientation: nil,
          expected_batches: [[Blur]],
          expected_measurements: 0
        },
        %{
          name: "pure shape advance",
          operations: [operation!(:rotate, [90])],
          pending_orientation: nil,
          expected_batches: [[], [Flush]],
          expected_measurements: 0
        },
        %{
          name: "relative resize",
          operations: [
            operation!(:resize, [:fit, {:ratio, 1, 2}, {:ratio, 1, 2}, [enlargement: :allow]])
          ],
          pending_orientation: nil,
          expected_batches: [[Resize]],
          expected_measurements: 1
        },
        %{
          name: "staged cover resize and crop",
          operations: [
            operation!(:resize, [:cover, {:px, 100}, {:px, 100}, [enlargement: :allow]])
          ],
          pending_orientation: nil,
          expected_batches: [[Resize], [Crop]],
          expected_measurements: 1
        },
        %{
          name: "guided crop",
          operations: [operation!(:crop_guided, [{:px, 120}, {:px, 80}, :bottom_right])],
          pending_orientation: nil,
          expected_batches: [[Crop]],
          expected_measurements: 0
        },
        %{
          name: "arbitrary rotation measurement",
          operations: [operation!(:rotate, [17])],
          pending_orientation: nil,
          expected_batches: [[Rotate]],
          expected_measurements: 1
        },
        %{
          name: "pending orientation boundary flush",
          operations: [operation!(:blur, [1.0])],
          pending_orientation: PendingOrientation.from_exif(6, true),
          expected_batches: [[Blur], [Flush]],
          expected_measurements: 0
        },
        %{
          name: "identity pending streaming",
          operations: [operation!(:blur, [1.0])],
          pending_orientation: PendingOrientation.from_exif(1, true),
          expected_batches: [[Blur]],
          expected_measurements: 0
        }
      ]

      Enum.each(cases, fn case_data ->
        dynamic = run(case_data, :dynamic)
        fixed = run(case_data, :fixed)

        assert fixed == dynamic, case_data.name

        assert Enum.map(fixed.batches, & &1.operations) == case_data.expected_batches,
               case_data.name

        assert length(fixed.measurements) == case_data.expected_measurements,
               case_data.name

        if case_data.name == "identity pending streaming" do
          refute fixed.final_state.materialized?
          assert fixed.final_state.pending_orientation == nil
        end
      end)
    end

    test "preserves chain error tags and stops both drivers at the same stage" do
      case_data = %{
        name: "chain error",
        operations: [operation!(:blur, [1.0])],
        pending_orientation: nil
      }

      dynamic = run(case_data, :dynamic, chain_error: {:transform, :chain_probe})
      fixed = run(case_data, :fixed, chain_error: {:transform, :chain_probe})

      assert fixed == dynamic
      assert fixed.result == {:error, {:transform, :chain_probe}}
      assert Enum.map(fixed.batches, & &1.operations) == [[Blur]]
      assert fixed.measurements == []
    end
  end

  defp run(case_data, driver, opts \\ []) do
    {:ok, image} = Image.new(320, 240, color: :white)

    events =
      start_supervised!({Agent, fn -> %{batches: [], measurements: []} end}, id: make_ref())

    state = %State{image: image}

    shape =
      SourceShape.seed(%{
        width: 320,
        height: 240,
        pending_orientation: case_data.pending_orientation,
        decode_shrink: nil
      })

    chain = recording_chain(events, Keyword.get(opts, :chain_error))
    measure_dims = recording_measurement(events)

    result =
      case driver do
        :dynamic ->
          Executor.run(
            case_data.operations,
            shape,
            {NeutralResolver, NeutralResolver.init()},
            state,
            chain: chain,
            measure_dims: measure_dims
          )

        :fixed ->
          Executor.run_neutral(case_data.operations, shape, state,
            chain: chain,
            measure_dims: measure_dims
          )
      end

    recorded = Agent.get(events, & &1)

    %{
      result: normalize_result(result),
      final_state: normalize_final_state(result),
      batches: Enum.reverse(recorded.batches),
      measurements: Enum.reverse(recorded.measurements)
    }
  end

  defp recording_chain(events, nil) do
    fn %State{} = state, operations, opts ->
      result = Chain.execute(state, operations, opts)
      record_batch(events, state, operations, result)
      result
    end
  end

  defp recording_chain(events, reason) do
    fn %State{} = state, operations, _opts ->
      result = {:error, reason}
      record_batch(events, state, operations, result)
      result
    end
  end

  defp recording_measurement(events) do
    fn image ->
      dimensions = dimensions(image)
      Agent.update(events, &update_in(&1.measurements, fn values -> [dimensions | values] end))
      dimensions
    end
  end

  defp record_batch(events, state, operations, result) do
    batch = %{
      operations: Enum.map(operations, & &1.__struct__),
      before: state_snapshot(state),
      after: normalize_result(result)
    }

    Agent.update(events, &update_in(&1.batches, fn values -> [batch | values] end))
  end

  defp normalize_result({:ok, %State{} = state}), do: {:ok, state_snapshot(state)}
  defp normalize_result({:error, _reason} = error), do: error

  defp normalize_final_state({:ok, %State{} = state}), do: state_snapshot(state)
  defp normalize_final_state({:error, _reason}), do: nil

  defp state_snapshot(%State{} = state) do
    state
    |> Map.from_struct()
    |> Map.delete(:image)
    |> Map.put(:image_dimensions, dimensions(state.image))
  end

  defp dimensions(image), do: {Image.width(image), Image.height(image)}

  defp operation!(name, arguments) do
    {:ok, operation} = apply(Operation, name, arguments)
    operation
  end
end
