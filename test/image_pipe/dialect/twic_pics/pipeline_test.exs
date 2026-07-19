defmodule ImagePipe.Dialect.TwicPics.PipelineTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Test.FakeDetector
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
  @twicpics_grid "test/support/image_pipe/test/twicpics_differential/sources/grid_4x4.png"
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
    request
  end

  defp recording_chain(pid) do
    fn state, ops, opts ->
      send(pid, {:ops, ops, State.effective_source_dims(state)})
      Chain.execute(state, ops, opts)
    end
  end

  test "executes ordered relative resizes as two measured semantic steps" do
    # Two relative resizes both execute — a later relative resize composes against
    # the running frame (50% of 50% of 800 = 200), so neither is shadowed.
    request = build([{"resize", "50p"}, {"resize", "50p"}])
    state = state_for(800, 600)

    assert {:ok, %State{} = out} =
             Pipeline.run(state, geometry(800, 600), request, chain: recording_chain(self()))

    assert Image.width(out.image) == 200
    assert_received {:ops, [%Resize{}], {800, 600}}
    assert_received {:ops, [%Resize{}], {400, 300}}
  end

  test "focus position, multiple consumers, region crop, and canvas preserve dialect pixels" do
    cases = [
      [{"focus", "top-right"}, {"resize", "50p"}, {"crop", "40x30"}, {"crop", "12x12"}],
      [{"resize", "50p"}, {"focus", "120x80"}, {"cover", "100x60"}],
      [{"focus", "300x200"}, {"crop", "200x160@40x30"}, {"crop", "30x20"}],
      [{"focus", "bottom-right"}, {"inside", "320x240"}, {"crop", "20x20"}]
    ]

    actual =
      for chain <- cases do
        request = build(chain)
        state = asymmetric_state_for(640, 480)

        assert {:ok, local} = Pipeline.run(state, geometry(640, 480), request, [])
        {chain, image_fingerprint(local.image)}
      end

    assert actual == [
             {Enum.at(cases, 0),
              {12, 12, "6bdea814046bb4ab642b0ba3f144317b605df0f836c04eae5913b00d0524074b"}},
             {Enum.at(cases, 1),
              {100, 60, "8a822a409dabdb0dbad82f4ae7e802b2c924925559f9e616349900c02ee603ec"}},
             {Enum.at(cases, 2),
              {30, 20, "8d82c044407b5f34494678b0aa98aae5f8f6a6588481dbcee93129fb4bae2487"}},
             {Enum.at(cases, 3),
              {20, 20, "e4a37f60e8ab43c7b0e6cdfd6dcb40fb6743d11a20e320e5864ed0ba05dc5ba8"}}
           ]
  end

  test "auto focus followed by a region crop resets before the next focused crop" do
    chain = [{"focus", "auto"}, {"crop", "500x300@100x100"}, {"crop", "160x100"}]
    request = build(chain)
    state = asymmetric_state_for(640, 480)

    assert {:ok, local} = Pipeline.run(state, geometry(640, 480), request, [])

    assert image_fingerprint(local.image) ==
             {160, 100, "ec844693139d5596ae7452fdfdf362f1b2f830cda90e9d273517ec18476a3acf"}
  end

  test "region crops and canvases advance the running frame seen by later operations" do
    request = build([{"crop", "200x150@50x40"}, {"inside", "300x220"}, {"resize", "50p"}])

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
    request = build([{"resize", "50p"}, {"crop", "40x30@5x4"}])
    state = state_for(80, 120, pending_orientation: pending)

    assert {:ok, local} =
             Pipeline.run(
               state,
               geometry(80, 120, pending),
               request,
               chain: recording_chain(self())
             )

    assert image_fingerprint(local.image) ==
             {40, 30, "7f59d226273d41083e6ad28762c535c25e46ff21512510e0ebd97c6a8b5e76ff"}

    messages = drain_ops([])

    assert 1 ==
             Enum.count(messages, fn {_, ops, _dims} -> Enum.any?(ops, &match?(%Flush{}, &1)) end)
  end

  test "two resize seams measure the image returned by their own stage" do
    request = build([{"cover", "300x200"}, {"contain", "90x70"}])

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
    request = build([{"cover", "300x200"}])

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
    request = build([{"resize", "40"}])
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

  test "focus auto detector modes preserve dialect pixels and telemetry" do
    chain = [{"focus", "auto"}, {"crop", "40x40"}]
    request = build(chain)

    actual =
      for {label, detector_opts} <- [
            {:configured, [detector: FakeDetector]},
            {:disabled, [detector: nil]},
            {:required_missing, [detector: nil, detector_required: true]}
          ] do
        state = %State{
          state_for(80, 60)
          | telemetry_opts: [telemetry_prefix: @detect_telemetry_prefix]
        }

        opts = Keyword.put(detector_opts, :telemetry_prefix, @detect_telemetry_prefix)

        {local, local_events} =
          capture_detect_events(@detect_telemetry_prefix, fn ->
            Pipeline.run(state, geometry(80, 60), request, opts)
          end)

        assert {:ok, local_state} = local

        {label, image_fingerprint(local_state.image), Enum.map(local_events, &elem(&1, 0))}
      end

    assert actual == [
             {:configured,
              {40, 40, "7be74e3f861e6b8ed78cd407c8583bad1a41bf617b2c267da7f1624f56a308ee"},
              [@detect_telemetry_prefix ++ [:transform, :detect, :stop]]},
             {:disabled,
              {40, 40, "7be74e3f861e6b8ed78cd407c8583bad1a41bf617b2c267da7f1624f56a308ee"},
              [@detect_telemetry_prefix ++ [:transform, :detect, :skipped]]},
             {:required_missing,
              {40, 40, "7be74e3f861e6b8ed78cd407c8583bad1a41bf617b2c267da7f1624f56a308ee"},
              [@detect_telemetry_prefix ++ [:transform, :detect, :skipped]]}
           ]
  end

  test "an absolute resize shadows the preceding relative resize (executes once)" do
    # TwicPics transformations reference: "a transformation may shadow what came
    # before it. resize=50p/resize=340 will result in an image that is 340
    # pixel-wide: TwicPics will simply ignore the first resize." Dropping the 50p
    # means resize=340 applies to the 400x400 source -> 340x340, executed as a
    # single semantic step. Closes #464.
    {:ok, image} = Image.open(@twicpics_grid)
    request = build([{"resize", "50p"}, {"resize", "340"}])

    assert {:ok, out} =
             Pipeline.run(%State{image: image}, geometry(400, 400), request,
               chain: recording_chain(self())
             )

    assert {Image.width(out.image), Image.height(out.image)} == {340, 340}
    assert_received {:ops, [%Resize{}], {400, 400}}
    refute_received {:ops, _ops, _dims}
  end

  test "nil-focus crops preserve exact pixels across pending orientation center biases" do
    image = fine_pattern(41, 81)

    actual =
      for orientation <- [2, 4, 6, 7], size <- [{20, 30}, {21, 31}, {20, 31}, {21, 30}] do
        carried = run_pending_crop(image, orientation, size)
        {orientation, size, image_fingerprint(carried)}
      end

    assert actual == [
             {2, {20, 30},
              {20, 30, "e29263e6ca96647b16c05564fd4fed4cc444d31d2d1f4c67e2ff699e9ddebcc8"}},
             {2, {21, 31},
              {21, 31, "ce82b466ef87965acc02f1632ec2ce2a06f120da2002ed463e39e7ec6bd8610f"}},
             {2, {20, 31},
              {20, 31, "8a7e0c52dd8b6f0d8a4bca033276f79b8f0659fef34ee5cbe2581e63e9b43b3d"}},
             {2, {21, 30},
              {21, 30, "abd15dc9b66699d80415694f7548b449eeceb01032fa8123b413da822623398a"}},
             {4, {20, 30},
              {20, 30, "5272c82a12c441599a82e418e8d944ef109df61937da0e912e4516619b6d1f02"}},
             {4, {21, 31},
              {21, 31, "584a7ae31a8b43c45eaf724ee9650e056c8e90a32b9b8494355a0491da8f3757"}},
             {4, {20, 31},
              {20, 31, "7c86c2c94b30e644b4b892f6b62792a937bf9fac641b6af583735d63ffc26ede"}},
             {4, {21, 30},
              {21, 30, "d8806002caea95a48432a45f32ad02a80482b0d2621c12a59321c2cff2952f7d"}},
             {6, {20, 30},
              {20, 30, "818e8cb9b06beaaf8588dac6d60c6cbf4c325caba54d17575feb488d0aa106c6"}},
             {6, {21, 31},
              {21, 31, "171fe74495eabfe1a95543d43fcdd2da331c8f185ebc427f713c600709b53e20"}},
             {6, {20, 31},
              {20, 31, "7159ed8a643d35c41e94bb381187d6ea494258fe4c0f288beeacdc431550b2a9"}},
             {6, {21, 30},
              {21, 30, "589349bf1da17f8b3effed4aa14f28b3a70b7dd2208c1c8efab2e3637b6cc917"}},
             {7, {20, 30},
              {20, 30, "43e58fddd1f3b7640ca7c67a76f6b2eb44a3a2def00b251a7b200a1453922828"}},
             {7, {21, 31},
              {21, 31, "cf56820deaa20e471004996ee2d3fa9fbbaf8e603c0a09656bef8b2b788f7651"}},
             {7, {20, 31},
              {20, 31, "fe3397cfce940f7dd37b3fa7f62e077c5a5ffcd8c89013f79200690461145488"}},
             {7, {21, 30},
              {21, 30, "4f0c932650a3ac2c5c24295366ea4d6f08b84d56e43c472442360bb80a3bfe10"}}
           ]
  end

  test "real execution consumes a genuinely sequential source" do
    body = File.read!(@beach)
    {:ok, control} = Image.open([body], access: :sequential, fail_on: :error)
    {:ok, rotated} = Image.rotate(control, 90)
    assert {:error, _reason} = VipsImage.copy_memory(rotated)

    {:ok, streamed} = Image.open([body], access: :sequential, fail_on: :error)
    {width, height} = {Image.width(streamed), Image.height(streamed)}
    request = build([{"resize", "320"}, {"crop", "200x120"}])

    assert {:ok, out} =
             Pipeline.run(%State{image: streamed}, geometry(width, height), request, [])

    assert {:ok, %VipsImage{}} = VipsImage.copy_memory(out.image)
  end

  defp empty_request do
    %Request{source: "test", steps: [], output: nil, response: nil, auto_rotate: true}
  end

  defp image_fingerprint(image) do
    {:ok, pixels} = VipsImage.write_to_binary(image)
    digest = :sha256 |> :crypto.hash(pixels) |> Base.encode16(case: :lower)
    {Image.width(image), Image.height(image), digest}
  end

  defp fine_pattern(width, height) do
    pixels =
      for y <- 0..(height - 1), x <- 0..(width - 1), into: <<>> do
        <<rem(x * 6, 256), rem(y * 3, 256), 200>>
      end

    {:ok, image} = VipsImage.new_from_binary(pixels, width, height, 3, :VIPS_FORMAT_UCHAR)
    image
  end

  defp run_pending_crop(image, orientation, {width, height}) do
    pending = PendingOrientation.from_exif(orientation, true)

    state = %State{
      image: Image.set_orientation!(image, orientation),
      pending_orientation: pending
    }

    request = build([{"crop", "#{width}x#{height}"}])

    assert {:ok, out} =
             Pipeline.run(state, geometry(41, 81, pending), request, [])

    out.image
  end

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
