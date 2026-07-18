defmodule ImagePipe.Dialect.TwicPics.PipelineTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Parser.TwicPics.PlanBuilder
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Test.FakeDetector
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Chain
  alias ImagePipe.Transform.Operation.Crop
  alias ImagePipe.Transform.Operation.ExtendCanvas
  alias ImagePipe.Transform.Operation.Flush
  alias ImagePipe.Transform.Operation.Resize
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  @beach "priv/static/images/beach.jpg"
  @p3 "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"
  @detect_telemetry_prefix [:image_pipe_twic_pics_pipeline_detect_test]

  defp state_for(width, height, opts \\ []) do
    {:ok, image} = Image.new(width, height, color: [120, 80, 40])

    %State{
      image: image,
      pending_orientation: Keyword.get(opts, :pending_orientation),
      decode_shrink: Keyword.get(opts, :decode_shrink)
    }
  end

  defp asymmetric_state_for(width, height) do
    image =
      for row <- 0..5, col <- 0..7 do
        color = [rem(col * 41 + row * 13, 256), rem(col * 17 + row * 47, 256), 255 - col * 19]
        Image.new!(div(width, 8), div(height, 6), color: color)
      end
      |> Image.join!(across: 8)

    detail =
      for row <- 0..5, col <- 0..5 do
        Image.new!(16, 16, color: checker_color(col + row))
      end
      |> Image.join!(across: 6)

    %State{image: Image.compose!(image, detail, x: 120, y: 120)}
  end

  defp checker_color(value) when rem(value, 2) == 0, do: [255, 255, 255]
  defp checker_color(_value), do: [0, 0, 0]

  defp exif_state_for(width, height, orientation) do
    body =
      width
      |> Image.new!(height, color: [120, 80, 40])
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")

    {:ok, image} = Image.open([body], access: :sequential, fail_on: :error)
    %State{image: image, pending_orientation: PendingOrientation.from_exif(orientation, true)}
  end

  defp geometry(width, height, pending \\ %PendingOrientation{}, format \\ :png) do
    %SourceGeometry{
      storage_dimensions: {width, height},
      display_dimensions: PendingOrientation.display_dims({width, height}, pending),
      pending_orientation: pending,
      source_format: format
    }
  end

  defp build(chain) do
    source = %Path{segments: ["x.png"]}
    config = ImagePipe.Config.resolve!([])
    {:ok, request} = RequestBuilder.build(source, chain, config)
    {:ok, plan} = PlanBuilder.to_plan(source, chain, config)
    {request, plan}
  end

  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops, State.effective_source_dims(state)})
      Chain.execute(state, ops, opts)
    end
  end

  test "executes ordered relative resizes as two measured semantic steps" do
    {request, _plan} = build([{"resize", "50p"}, {"resize", "340"}])
    state = state_for(800, 600)

    assert {:ok, %State{} = out} =
             Pipeline.run(state, geometry(800, 600), request, chain: recording_chain(self()))

    assert Image.width(out.image) == 340
    assert_received {:ops, [%Resize{}], {800, 600}}
    assert_received {:ops, [%Resize{}], {400, 300}}
  end

  test "focus position, multiple consumers, region crop, and canvas match the framework pixels" do
    cases = [
      [{"focus", "top-right"}, {"resize", "50p"}, {"crop", "40x30"}, {"crop", "12x12"}],
      [{"resize", "50p"}, {"focus", "120x80"}, {"cover", "100x60"}],
      [{"focus", "300x200"}, {"crop", "200x160@40x30"}, {"crop", "30x20"}],
      [{"focus", "bottom-right"}, {"inside", "320x240"}, {"crop", "20x20"}]
    ]

    for chain <- cases do
      {request, plan} = build(chain)
      state = asymmetric_state_for(640, 480)

      assert {:ok, local} = Pipeline.run(state, geometry(640, 480), request, [])
      assert {:ok, legacy} = Transform.execute_plan(plan, state, [])

      assert png(local.image) == png(legacy.image), "pixel mismatch for #{inspect(chain)}"
    end
  end

  test "auto focus followed by a region crop resets before the next focused crop" do
    chain = [{"focus", "auto"}, {"crop", "500x300@100x100"}, {"crop", "160x100"}]
    {request, plan} = build(chain)
    state = asymmetric_state_for(640, 480)

    assert {:ok, local} = Pipeline.run(state, geometry(640, 480), request, [])
    assert {:ok, legacy} = Transform.execute_plan(plan, state, [])
    assert png(local.image) == png(legacy.image)
  end

  test "region crops and canvases advance the running frame seen by later operations" do
    {request, _plan} =
      build([{"crop", "200x150@50x40"}, {"inside", "300x220"}, {"resize", "50p"}])

    assert {:ok, %State{} = out} =
             Pipeline.run(
               state_for(500, 400),
               geometry(500, 400),
               request,
               chain: recording_chain(self())
             )

    assert Image.width(out.image) == 150
    assert Image.height(out.image) == 110
    assert_received {:ops, [%Crop{}], {500, 400}}
    assert_received {:ops, [%ExtendCanvas{}], {200, 150}}
  end

  test "a pending EXIF orientation flushes exactly once at the request boundary" do
    pending = PendingOrientation.from_exif(6, true)
    {request, plan} = build([{"resize", "50p"}, {"crop", "40x30@5x4"}])
    state = state_for(80, 120, pending_orientation: pending)

    assert {:ok, local} =
             Pipeline.run(
               state,
               geometry(80, 120, pending),
               request,
               chain: recording_chain(self())
             )

    assert {:ok, legacy} = Transform.execute_plan(plan, state, [])
    assert png(local.image) == png(legacy.image)

    messages = drain_ops([])

    assert 1 ==
             Enum.count(messages, fn {_, ops, _dims} -> Enum.any?(ops, &match?(%Flush{}, &1)) end)
  end

  test "two resize seams measure the image returned by their own stage" do
    {request, _plan} = build([{"cover", "300x200"}, {"contain", "90x70"}])

    assert {:ok, %State{} = out} =
             Pipeline.run(
               state_for(640, 480),
               geometry(640, 480),
               request,
               chain: recording_chain(self())
             )

    assert {Image.width(out.image), Image.height(out.image)} == {90, 60}
    assert length(Enum.filter(drain_ops([]), fn {_, ops, _} -> match?([%Resize{}], ops) end)) == 2
  end

  test "a continuation tail consumes the preceding State without a second overlay" do
    {request, _plan} = build([{"cover", "300x200"}])

    assert {:ok, %State{}} =
             Pipeline.run(
               state_for(640, 480),
               geometry(640, 480),
               request,
               chain: recording_chain(self())
             )

    assert [
             {:ops, [%Resize{}], {640, 480}},
             {:ops, [%Crop{}], {300, 225}}
           ] = drain_ops([])
  end

  test "empty steps still perform the single orientation boundary" do
    pending = PendingOrientation.from_exif(6, true)
    request = empty_request()

    assert {:ok, out} =
             Pipeline.run(
               exif_state_for(40, 80, 6),
               geometry(40, 80, pending, :jpeg),
               request,
               chain: recording_chain(self())
             )

    assert {Image.width(out.image), Image.height(out.image)} == {80, 40}
    assert_received {:ops, [%Flush{}], {40, 80}}
  end

  test "chain failures are tagged as transform failures" do
    {request, _plan} = build([{"resize", "40"}])
    failing = fn _state, _ops, _opts -> {:error, :forced_chain_failure} end

    assert {:error, {:transform, :forced_chain_failure}} =
             Pipeline.run(state_for(80, 60), geometry(80, 60), request, chain: failing)
  end

  test "the input-color preamble runs before operations and stamps the carry" do
    {:ok, image} = Image.open(@p3)
    request = empty_request()

    assert {:ok, %State{} = out} =
             Pipeline.run(%State{image: image}, geometry(512, 512), request, [])

    assert out.color_imported?
    assert is_binary(out.source_color_profile)
  end

  test "focus auto detector modes match framework pixels and telemetry" do
    chain = [{"focus", "auto"}, {"crop", "40x40"}]
    {request, plan} = build(chain)

    for {label, detector_opts, expected_suffix} <- [
          {:configured, [detector: FakeDetector], [:transform, :detect, :stop]},
          {:disabled, [detector: nil], [:transform, :detect, :skipped]},
          {:required_missing, [detector: nil, detector_required: true],
           [:transform, :detect, :skipped]}
        ] do
      state = %State{
        state_for(80, 60)
        | telemetry_opts: [telemetry_prefix: @detect_telemetry_prefix]
      }

      opts = Keyword.put(detector_opts, :telemetry_prefix, @detect_telemetry_prefix)
      expected_event = @detect_telemetry_prefix ++ expected_suffix

      {local, local_events} =
        capture_detect_events(@detect_telemetry_prefix, fn ->
          Pipeline.run(state, geometry(80, 60), request, opts)
        end)

      {legacy, legacy_events} =
        capture_detect_events(@detect_telemetry_prefix, fn ->
          Transform.execute_plan(plan, state, opts)
        end)

      assert {:ok, local_state} = local
      assert {:ok, legacy_state} = legacy
      assert png(local_state.image) == png(legacy_state.image), "#{label} pixel parity"
      assert Enum.map(local_events, &elem(&1, 0)) == Enum.map(legacy_events, &elem(&1, 0))
      assert Enum.any?(local_events, &(elem(&1, 0) == expected_event))
    end
  end

  test "real execution consumes a genuinely sequential source" do
    body = File.read!(@beach)
    {:ok, control} = Image.open([body], access: :sequential, fail_on: :error)
    {:ok, rotated} = Image.rotate(control, 90)
    assert {:error, _reason} = VipsImage.copy_memory(rotated)

    {:ok, streamed} = Image.open([body], access: :sequential, fail_on: :error)
    {width, height} = {Image.width(streamed), Image.height(streamed)}
    {request, _plan} = build([{"resize", "320"}, {"crop", "200x120"}])

    assert {:ok, out} =
             Pipeline.run(%State{image: streamed}, geometry(width, height), request, [])

    assert {:ok, %VipsImage{}} = VipsImage.copy_memory(out.image)
  end

  test "continuation recursion is capped" do
    {request, _plan} = build([{"resize", "40"}])
    identity_chain = fn state, _ops, _opts -> {:ok, state} end
    bogus_continue = fn _tag, _dims, _shape, seam -> {[], {:measure, :again, seam}} end

    assert_raise FunctionClauseError, fn ->
      Pipeline.run(state_for(80, 60), geometry(80, 60), request,
        chain: identity_chain,
        continue: bogus_continue
      )
    end
  end

  defp empty_request do
    %Request{source: "test", steps: [], output: nil, response: nil, auto_rotate: true}
  end

  defp png(image), do: Image.write!(image, :memory, suffix: ".png")

  defp drain_ops(acc) do
    receive do
      {:ops, _ops, _dims} = message -> drain_ops([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp capture_detect_events(prefix, fun) do
    ref = make_ref()

    events =
      Enum.map(
        [
          [:transform, :detect, :stop],
          [:transform, :detect, :skipped],
          [:transform, :detect, :blend]
        ],
        &(prefix ++ &1)
      )

    :ok =
      :telemetry.attach_many(
        ref,
        events,
        &__MODULE__.handle_detect_event/4,
        {self(), ref}
      )

    result = fun.()
    :telemetry.detach(ref)
    {result, drain_events(ref, [])}
  end

  defp drain_events(ref, acc) do
    receive do
      {^ref, event, metadata} -> drain_events(ref, [{event, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  def handle_detect_event(event, _measurements, metadata, {pid, ref}) do
    send(pid, {ref, event, Map.take(metadata, [:result, :regions, :classes])})
  end
end
