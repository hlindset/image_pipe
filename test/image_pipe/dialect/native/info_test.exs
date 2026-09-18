defmodule ImagePipe.Native.InfoTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Native
  alias ImagePipe.Native.Config
  alias ImagePipe.Native.Info
  alias ImagePipe.Native.Parser
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Source
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImgproxyWireConformanceTest.OriginImage

  @sources [
    path:
      {RootHTTPAdapter,
       root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage]}
  ]

  test "renders canonical source format names, display dimensions, and optional size" do
    info = %SourceInfo{
      format: :jpeg_xl,
      width: 40,
      height: 80,
      orientation: 6,
      byte_size: 12_345
    }

    assert {"application/json", body} = Info.render(info)

    assert body |> IO.iodata_to_binary() |> JSON.decode!() == %{
             "format" => "jpeg_xl",
             "mime_type" => "image/jxl",
             "width" => 80,
             "height" => 40,
             "orientation" => 6,
             "size" => 12_345
           }
  end

  test "omits unavailable source size" do
    info = %SourceInfo{format: :heif, width: 10, height: 20, orientation: 1}

    assert {"application/json", body} = Info.render(info)

    refute body |> IO.iodata_to_binary() |> JSON.decode!() |> Map.has_key?("size")
  end

  test "reads source facts without applying transforms or encoding" do
    config = SharedConfig.validate_runtime!(sources: @sources)
    source = %Path{segments: ["images", "beach.jpg"]}
    assert {:ok, resolved} = Source.resolve(source, config, config)

    assert {:ok, "application/json", body} = Info.render_source(resolved, config)

    assert %{
             "format" => "jpeg",
             "mime_type" => "image/jpeg",
             "width" => 4000,
             "height" => 2667,
             "orientation" => 1,
             "size" => size
           } = body |> IO.iodata_to_binary() |> JSON.decode!()

    assert is_integer(size) and size > 0
  end

  test "native info and BlurHash computations emit output terminal spans" do
    prefix = [:native_terminal_info_test]
    config = Config.validate!(sources: @sources, telemetry_prefix: prefix)
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        prefix ++ [:output, :terminal, :stop],
        fn _event, _measurements, metadata, receiver -> send(receiver, {:terminal, metadata}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    assert {:ok, "application/json", _body} = render_terminal(["output=info"], config)
    assert_receive {:terminal, %{terminal: :info, result: :ok}}

    assert {:ok, "text/plain", _body} = render_terminal(["output=blurhash"], config)
    assert_receive {:terminal, %{terminal: :blurhash, result: :ok}}
  end

  defp render_terminal(segments, config) do
    lexed = %{
      segments: Enum.map(segments, &{&1, {0, byte_size(&1)}}),
      source: {:src, "images/beach.jpg", {0, 16}}
    }

    assert {:ok, request} = Parser.parse(lexed, config)
    assert {:ok, resolved_request} = Native.prepare(Plug.Test.conn(:get, "/"), request, config)
    assert {:ok, resolved_source} = Source.resolve(resolved_request.source, config, config)
    assert {:render, %RenderTerminal{fun: fun}} = resolved_request.terminal
    fun.(resolved_source, config)
  end
end
