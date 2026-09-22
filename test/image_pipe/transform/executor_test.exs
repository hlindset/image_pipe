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
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}
        ],
        max_body_bytes: 10_000_000,
        max_input_pixels: 10_000_000
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
    {:ok, lexed} = Plug.Test.conn(:get, path) |> Path.extract()
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
