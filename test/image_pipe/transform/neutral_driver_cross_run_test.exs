defmodule ImagePipe.Transform.NeutralDriverCrossRunTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Parser.IIIF.PlanBuilder
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Source.Path, as: SourcePath
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
  alias Vix.Vips.Image, as: VipsImage

  @source %SourcePath{segments: ["images", "source.jpg"]}
  @high_freq "test/support/image_pipe/test/imgproxy_differential/sources/high_freq.jpg"
  @exif6 "test/support/image_pipe/test/imgproxy_differential/sources/exif_6.jpg"
  @p3 "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"
  @telemetry_prefix [:neutral_driver_cross_run]
  @preamble_start @telemetry_prefix ++ [:transform, :input_color_management, :start]
  @preamble_stop @telemetry_prefix ++ [:transform, :input_color_management, :stop]

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

  describe "execute_neutral/3" do
    test "matches the injected neutral strategy for representative IIIF Plans and pixels" do
      cases = [
        {"no geometry", tokens()},
        {"pixel region", tokens(region: {:px, 100, 75, 800, 600})},
        {"percent region",
         tokens(region: {:pct, {:ratio, 1, 10}, {:ratio, 1, 10}, {:ratio, 3, 4}, {:ratio, 2, 3}})},
        {"bounded max", tokens(), [max_width: 600]},
        {"width only", tokens(size: {:w, 500, false})},
        {"height only", tokens(size: {:h, 400, false})},
        {"confined", tokens(size: {:confined, 500, 350, false})},
        {"percent scale", tokens(size: {:pct, {:ratio, 1, 2}, false})},
        {"mirror", tokens(rotation: {true, 0})},
        {"right-angle rotate", tokens(rotation: {false, 90})},
        {"arbitrary rotate", tokens(rotation: {false, 17})},
        {"gray", tokens(quality: :gray)},
        {"bitonal", tokens(quality: :bitonal)}
      ]

      Enum.each(cases, fn case_data ->
        {name, tokens, extra_opts} = normalize_case(case_data)
        plan = plan!(tokens, extra_opts)
        {dynamic, fixed} = execute_pair(plan, @high_freq)

        assert_success_parity(dynamic, fixed, name)
      end)
    end

    test "matches emitted stage boundaries and measurement calls" do
      plan =
        plan!(
          tokens(
            region: {:px, 100, 75, 800, 600},
            size: {:confined, 300, 300, false},
            rotation: {false, 17},
            quality: :gray
          )
        )

      dynamic = execute_recording(plan, @high_freq, :dynamic)
      fixed = execute_recording(plan, @high_freq, :fixed)

      assert fixed == dynamic
      assert length(fixed.measurements) == 2
      assert Enum.count(fixed.batches, &(&1.operations == [Resize])) == 1
      assert Enum.count(fixed.batches, &(&1.operations == [Rotate])) == 1
    end

    test "preserves transform and decode error tags from the shared chain" do
      plan = plan!(tokens(size: {:w, 500, false}))

      Enum.each([{:transform, :stage_probe}, {:decode, :stage_probe}], fn reason ->
        error_chain = fn _state, _operations, _opts -> {:error, reason} end

        dynamic =
          Executor.execute(%Plan{plan | resolver: NeutralResolver}, state(@high_freq),
            chain: error_chain
          )

        fixed =
          Executor.execute_neutral(%Plan{plan | resolver: nil}, state(@high_freq),
            chain: error_chain
          )

        assert dynamic == {:error, reason}
        assert fixed == dynamic
      end)
    end

    test "seeds EXIF orientation and embedded-profile color management once per arm" do
      handler_id = {__MODULE__, :neutral_driver_preamble, make_ref()}

      :ok =
        :telemetry.attach_many(
          handler_id,
          [
            @preamble_start,
            @preamble_stop
          ],
          &__MODULE__.handle_telemetry_event/4,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      plan = plan!(tokens())
      execution_opts = [seed_orientation: true, telemetry_prefix: @telemetry_prefix]
      {dynamic_exif, fixed_exif} = execute_pair(plan, @exif6, execution_opts)
      assert_success_parity(dynamic_exif, fixed_exif, "EXIF preamble")
      assert {:ok, %State{} = exif_state} = fixed_exif
      assert exif_state.pending_orientation == nil
      assert dimensions(exif_state.image) == {300, 400}
      assert_one_preamble_per_arm(false)

      {dynamic_p3, fixed_p3} = execute_pair(plan, @p3, execution_opts)
      assert_success_parity(dynamic_p3, fixed_p3, "color preamble")
      assert {:ok, %State{} = p3_state} = fixed_p3
      assert p3_state.color_imported?
      assert is_binary(p3_state.source_color_profile)
      assert_one_preamble_per_arm(true)
    end
  end

  @doc false
  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:preamble_event, event, measurements, metadata})
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

  defp tokens(overrides \\ []) do
    [
      region: :full,
      size: {:max, false},
      rotation: {false, 0},
      quality: :default,
      format: :png
    ]
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  defp plan!(tokens, extra_opts \\ []) do
    opts =
      ImagePipe.Config.resolve!([])
      |> Keyword.merge(extra_opts)
      |> Keyword.put(:auto_rotate, true)

    {:ok, plan} = PlanBuilder.image_plan(@source, tokens, opts)
    plan
  end

  defp normalize_case({name, tokens}), do: {name, tokens, []}
  defp normalize_case({name, tokens, opts}), do: {name, tokens, opts}

  defp execute_pair(%Plan{} = plan, path, opts \\ []) do
    dynamic =
      Executor.execute(%Plan{plan | resolver: NeutralResolver}, state(path), opts)

    fixed =
      Executor.execute_neutral(%Plan{plan | resolver: nil}, state(path), opts)

    {dynamic, fixed}
  end

  defp execute_recording(%Plan{} = plan, path, driver) do
    events =
      start_supervised!({Agent, fn -> %{batches: [], measurements: []} end}, id: make_ref())

    chain = fn %State{} = state, operations, opts ->
      result = Chain.execute(state, operations, opts)

      batch = %{
        operations: Enum.map(operations, & &1.__struct__),
        source_dimensions: state.source_dimensions,
        result: normalize_result(result)
      }

      Agent.update(events, &update_in(&1.batches, fn values -> [batch | values] end))
      result
    end

    measure_dims = fn image ->
      measured = dimensions(image)
      Agent.update(events, &update_in(&1.measurements, fn values -> [measured | values] end))
      measured
    end

    result =
      case driver do
        :dynamic ->
          Executor.execute(%Plan{plan | resolver: NeutralResolver}, state(path),
            chain: chain,
            measure_dims: measure_dims
          )

        :fixed ->
          Executor.execute_neutral(%Plan{plan | resolver: nil}, state(path),
            chain: chain,
            measure_dims: measure_dims
          )
      end

    recorded = Agent.get(events, & &1)

    %{
      result: normalize_result(result),
      batches: Enum.reverse(recorded.batches),
      measurements: Enum.reverse(recorded.measurements)
    }
  end

  defp state(path), do: %State{image: Image.open!(path, access: :random, fail_on: :error)}

  defp assert_success_parity({:ok, dynamic}, {:ok, fixed}, context) do
    assert state_snapshot(fixed) == state_snapshot(dynamic), context
    assert image_snapshot(fixed.image) == image_snapshot(dynamic.image), context
  end

  defp assert_success_parity(dynamic, fixed, context) do
    flunk(
      "#{context}: expected two successful arms, got #{inspect(dynamic)} and #{inspect(fixed)}"
    )
  end

  defp image_snapshot(image) do
    {:ok, pixels} = VipsImage.write_to_binary(image)

    %{
      dimensions: dimensions(image),
      bands: VipsImage.bands(image),
      format: VipsImage.format(image),
      interpretation: VipsImage.interpretation(image),
      pixels: pixels
    }
  end

  defp assert_one_preamble_per_arm(imported?) do
    for _ <- 1..2 do
      assert_receive {:preamble_event, @preamble_start, _, _}
    end

    for _ <- 1..2 do
      assert_receive {:preamble_event, @preamble_stop, _, %{result: :ok, imported?: ^imported?}}
    end

    refute_receive {:preamble_event, _, _, _}, 10
  end

  defp operation!(name, arguments) do
    {:ok, operation} = apply(Operation, name, arguments)
    operation
  end
end
