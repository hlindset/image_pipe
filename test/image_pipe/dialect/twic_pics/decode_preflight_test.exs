defmodule ImagePipe.Dialect.TwicPics.DecodePreflightTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Dialect.TwicPics.Shadow
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  defp build(chain) do
    {:ok, request} =
      RequestBuilder.build(
        %Path{segments: ["x.jpg"]},
        chain,
        ImagePipe.Config.resolve!([])
      )

    request
  end

  defp geometry({width, height}, pending \\ %PendingOrientation{}, format \\ :jpeg) do
    %SourceGeometry{
      storage_dimensions: {width, height},
      display_dimensions: PendingOrientation.display_dims({width, height}, pending),
      pending_orientation: pending,
      source_format: format
    }
  end

  # The reference runtime op-chain is the shadow-collapsed execution stream, the
  # same stream Pipeline.run assembles; preflight must converge with it.
  defp operation_chain(%Request{steps: steps}) do
    steps
    |> Shadow.execution_steps()
    |> Enum.flat_map(fn
      {:operation, operation} -> [operation]
      {:focused, operation} -> [operation]
      {:set_focus, _operand} -> []
      :set_auto_focus -> []
    end)
  end

  defp assert_converges(chain, dims, format, pending) do
    request = build(chain)
    geometry = geometry(dims, pending, format)
    exif_quarter_turn? = PendingOrientation.quarter_turn?(pending)

    assert DecodePlanner.open_options_for(
             Pipeline.decode_request(request, geometry),
             format,
             dims,
             exif_quarter_turn?,
             request.auto_rotate
           ) ==
             DecodePlanner.open_options(
               operation_chain(request),
               format,
               dims,
               exif_quarter_turn?,
               request.auto_rotate
             )
  end

  test "table converges with the literal legacy op-chain path" do
    pending = PendingOrientation.from_exif(6, true)

    cases = [
      {[{"resize", "340"}], {4000, 2667}, :jpeg, %PendingOrientation{}},
      {[{"resize", "200x300"}], {1800, 3200}, :webp, %PendingOrientation{}},
      {[{"resize", "x300"}], {1800, 3200}, :jpeg, %PendingOrientation{}},
      {[{"resize", "50p"}], {4000, 2667}, :webp, %PendingOrientation{}},
      {[{"crop", "800x600"}, {"resize", "200"}], {4000, 2667}, :jpeg, %PendingOrientation{}},
      {[{"crop", "50px25p"}, {"resize", "200x100"}], {3200, 2400}, :webp, %PendingOrientation{}},
      {[{"crop", "800x600@20x30"}, {"resize", "200"}], {4000, 2667}, :jpeg,
       %PendingOrientation{}},
      {[{"focus", "top-right"}, {"resize", "300"}], {1200, 1800}, :webp, pending},
      {[{"resize", "300"}, {"resize", "50"}], {4000, 2667}, :jpeg, %PendingOrientation{}},
      {[], {4000, 2667}, :jpeg, %PendingOrientation{}},
      {[{"resize", "50p"}, {"resize", "340"}], {4000, 2667}, :jpeg, %PendingOrientation{}}
    ]

    for {chain, dims, format, orientation} <- cases do
      assert_converges(chain, dims, format, orientation)
    end
  end

  test "an absolute resize shadows the preceding relative resize in preflight (#464)" do
    request = build([{"resize", "50p"}, {"resize", "340"}])
    preflight = Pipeline.decode_request(request, geometry({4000, 2667}))

    # The 50p is shadowed, so preflight targets the absolute 340 directly and
    # plans the same shrink-on-load as a bare resize=340 would.
    assert preflight.resize_target == {340.0, nil}

    {:ok, direct} = Operation.resize(:fit, {:px, 340}, :auto)

    assert DecodePlanner.open_options_for(preflight, :jpeg, {4000, 2667}, false, true) ==
             DecodePlanner.open_options([direct], :jpeg, {4000, 2667}, false, true)
  end

  test "preceding crop extent is derived and focus-only steps are ignored" do
    request =
      build([{"focus", "bottom-right"}, {"crop", "50px25p"}, {"resize", "200"}])

    assert %DecodePlanner.Request{resize_target: {200.0, nil}, crop_extent: {1600, 600}} =
             Pipeline.decode_request(
               request,
               geometry({3200, 2400}, %PendingOrientation{}, :webp)
             )
  end

  property "an adjacent later pixel resize shadows a relative first resize (#464)" do
    check all width <- integer(800..5000),
              height <- integer(800..5000),
              percent <- integer(1..100),
              later <- integer(1..700),
              format <- member_of([:jpeg, :webp]),
              max_runs: 60 do
      request = build([{"resize", "#{percent}p"}, {"resize", "#{later}"}])
      {:ok, direct} = Operation.resize(:fit, {:px, later}, :auto)

      preflight =
        Pipeline.decode_request(request, geometry({width, height}, %PendingOrientation{}, format))

      # The relative first resize is shadowed, so preflight converges with a bare
      # resize=<later> against the source frame.
      assert DecodePlanner.open_options_for(preflight, format, {width, height}, false, true) ==
               DecodePlanner.open_options([direct], format, {width, height}, false, true)
    end
  end
end
