defmodule ImagePipe.Transform.ExecutorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.API.Parser
  alias ImagePipe.API.Path
  alias ImagePipe.Decode
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Operation

  test "executes parsed groups against each preceding group's live dimensions" do
    request = request!("w=50/h=40/fit=stretch/-/region=10,5,20,15")
    state = state!(100, 80)

    assert {:ok, result} = Executor.execute(state, request, [])
    assert {Image.width(result.image), Image.height(result.image)} == {20, 15}
  end

  test "rescales source-pixel regions once for a shrink-on-load decode" do
    request = request!("region=80,40,160,80")

    state = %State{
      state!(100, 75)
      | source_dimensions: {800, 600},
        decode_shrink: %{w: 8.0, h: 8.0}
    }

    assert {:ok, result} = Executor.execute(state, request, [])
    assert {Image.width(result.image), Image.height(result.image)} == {20, 10}
    assert result.source_dimensions == nil
    assert result.decode_shrink == nil
  end

  # A region at 101 sits at 50.5 shrunk pixels, which rounds half to even, as
  # gravity offsets do.
  test "a region's origin on a shrunk decode rounds half to even" do
    {:ok, columns} = Operation.xyz(200, 150)
    {:ok, columns} = Operation.extract_band(columns, 0)
    {:ok, columns} = Operation.cast(columns, :VIPS_FORMAT_UCHAR)

    state = %State{
      image: columns,
      source_dimensions: {400, 300},
      decode_shrink: %{w: 2.0, h: 2.0}
    }

    assert {:ok, result} = Executor.execute(state, request!("region=101,51,201,101"), [])
    assert {:ok, [column | _bands]} = Image.get_pixel(result.image, 0, 0)
    assert column == 50
  end

  test "rejects wholly outside regions while clamping partial overlap" do
    state = state!(100, 100)

    assert {:error, {:transform, {:bad_request, :region_out_of_bounds}}} =
             Executor.execute(state, request!("region=500,500,10,10"), [])

    assert {:ok, result} = Executor.execute(state, request!("region=90,90,20,20"), [])
    assert {Image.width(result.image), Image.height(result.image)} == {20, 20}
  end

  test "region coordinates after a deferred quarter turn use the display frame" do
    source = quadrant_image!()
    request = request!("rotate=90/region=0,0,20,30")
    reference_request = request!("region=0,0,20,30")

    assert {:ok, actual} = Executor.execute(%State{image: source}, request, [])
    rotated = Image.rotate!(source, 90)
    assert {:ok, expected} = Executor.execute(%State{image: rotated}, reference_request, [])

    assert pixels(actual.image) == pixels(expected.image)
  end

  test "builds decode preflight from the first parsed group and terminal crop extent" do
    request = request!("region=0,0,32,32/output=blurhash")

    geometry = %SourceGeometry{
      storage_dimensions: {800, 600},
      display_dimensions: {800, 600},
      pending_orientation: %PendingOrientation{},
      source_format: :jpeg
    }

    assert %{crop_extent: {32, 32}, terminal_reduction: {32, 32}} =
             Executor.decode_request(request, geometry)
  end

  # A contained image fills the box on one axis only, so the decode is planned
  # from the size the resize produces: 1600x1200 into 400x400 is 400x300, a
  # shrink of 4 on both axes, not min(4, 3) from the box.
  test "plans a contain resize's decode from the fitted size" do
    geometry = %SourceGeometry{
      storage_dimensions: {1600, 1200},
      display_dimensions: {1600, 1200},
      pending_orientation: %PendingOrientation{},
      source_format: :webp
    }

    planned = fn options ->
      {width, height} = Executor.decode_request(request!(options), geometry).resize_target
      {round(width), round(height)}
    end

    assert planned.("w=400/h=400/fit=contain") == {400, 300}
    assert planned.("w=200/h=200/fit=contain/dpr=2") == {400, 300}
    assert planned.("w=400/h=400/fit=cover") == {400, 400}
  end

  test "reduces parsed blurhash output to its fixed contain frame" do
    request = request!("output=blurhash")

    assert {:ok, result} =
             state!(320, 240)
             |> Executor.execute(request, [])
             |> then(fn {:ok, state} -> Executor.reduce_terminal(state, request.output, []) end)

    assert {Image.width(result.image), Image.height(result.image)} == {32, 24}
  end

  test "terminal reduction keeps the displayed aspect after a real shrunk quarter turn" do
    request = request!("rotate=90/output=blurhash")

    jpeg =
      Image.new!(3200, 2400, color: [80, 120, 160])
      |> Image.write!(:memory, suffix: ".jpg")

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, jpeg)
    end

    opts =
      Source.validate_config!(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        max_body_bytes: 10_000_000,
        max_input_pixels: 10_000_000,
        max_input_frames: 1_000
      )

    {:ok, resolved} = Source.resolve(%SourcePath{segments: ["image"]}, opts, [])

    assert {:ok, {24, 32}} =
             Decode.with_image(
               resolved,
               request,
               opts,
               fn state, _geometry ->
                 assert {Image.width(state.image), Image.height(state.image)} == {400, 300}
                 assert {:ok, state} = Executor.execute(state, request, [])
                 assert state.source_dimensions == {2400, 3200}
                 assert {:ok, result} = Executor.reduce_terminal(state, request.output, [])
                 {:ok, {Image.width(result.image), Image.height(result.image)}}
               end
             )
  end

  defp request!(options) do
    path = "/" <> options <> if(options == "", do: "", else: "/") <> "src/test"
    {:ok, lexed} = Path.extract(path, "")
    {:ok, request} = Parser.parse(lexed, [])
    request
  end

  defp state!(width, height) do
    %State{image: Image.new!(width, height, color: [80, 120, 160])}
  end

  defp quadrant_image! do
    top = Image.new!(60, 20, color: [255, 0, 0])
    bottom = Image.new!(60, 20, color: [0, 0, 255])
    Image.join!([top, bottom], across: 1)
  end

  defp pixels(image), do: Image.write!(image, :memory, suffix: ".png")
end
