defmodule ImagePipe.Dialect.TwicPics.DecodePreflightTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
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

  defp operation_chain(%Request{steps: steps}) do
    Enum.flat_map(steps, fn
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

  test "the first relative resize stops preflight and normalizes its empty target to nil" do
    request = build([{"resize", "50p"}, {"resize", "340"}])
    preflight = Pipeline.decode_request(request, geometry({4000, 2667}))

    assert preflight.resize_target == nil

    assert DecodePlanner.open_options_for(preflight, :jpeg, {4000, 2667}, false, true) ==
             [access: :sequential, fail_on: :error]

    {:ok, later} = Operation.resize(:fit, {:px, 340}, :auto)

    assert DecodePlanner.open_options([later], :jpeg, {4000, 2667}, false, true) ==
             [access: :sequential, fail_on: :error, shrink: 8]
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

  property "a relative first resize can never be shadowed by a later pixel resize" do
    check all width <- integer(800..5000),
              height <- integer(800..5000),
              percent <- integer(1..100),
              later <- integer(1..700),
              format <- member_of([:jpeg, :webp]),
              max_runs: 60 do
      {:ok, first} = Operation.resize(:fit, {:ratio, percent, 100}, :auto)
      {:ok, second} = Operation.resize(:fit, {:px, later}, :auto)

      request = %Request{
        source: "test",
        steps: [{:operation, first}, {:operation, second}],
        output: nil,
        response: nil,
        auto_rotate: true
      }

      preflight =
        Pipeline.decode_request(request, geometry({width, height}, %PendingOrientation{}, format))

      assert preflight.resize_target == nil

      assert DecodePlanner.open_options_for(preflight, format, {width, height}, false, true) ==
               DecodePlanner.open_options([first, second], format, {width, height}, false, true)
    end
  end
end
