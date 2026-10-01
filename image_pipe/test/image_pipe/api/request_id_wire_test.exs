defmodule ImagePipe.API.RequestIdWireTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog, only: [with_log: 1]
  import Plug.Test

  alias ImagePipe.ProcessingPool
  alias ImagePipe.Test.PlugFixture.CacheProbe
  alias ImagePipe.Test.ProcessingSource

  @image File.read!("priv/static/images/beach.jpg")

  defmodule RaisingEncoderImage do
    def stream!(_image, _options) do
      Stream.resource(fn -> :raise end, fn :raise -> raise "boom" end, fn _state -> :ok end)
    end
  end

  setup %{test: test} do
    prefix = [__MODULE__, test]
    test_pid = self()

    events =
      for stage <- [
            [:request],
            [:processing, :admission],
            [:processing, :execute],
            [:source, :fetch_decode],
            [:transform, :execute],
            [:encode],
            [:cache, :write],
            [:deliver]
          ] do
        prefix ++ stage ++ [:stop]
      end

    handler = {__MODULE__, test}
    :telemetry.attach_many(handler, events, &__MODULE__.handle_event/4, test_pid)

    on_exit(fn -> :telemetry.detach(handler) end)
    %{prefix: prefix, pool: start_supervised!({ProcessingPool, max_concurrency: 1})}
  end

  test "stage events in every request process carry the response's request ID", context do
    store = :ets.new(:request_id_cache, [:set, :public])
    mount = mount(context, @image, cache: {CacheProbe, store: store})

    conn = request(mount, "w=32/format=png")

    assert conn.status == 200
    id = response_id(conn)

    events =
      for stage <- [
            [:processing, :admission],
            [:processing, :execute],
            [:source, :fetch_decode],
            [:transform, :execute],
            [:encode],
            [:cache, :write],
            [:deliver],
            [:request]
          ] do
        assert {pid, ^id, _metadata} = event(context.prefix, stage)
        pid
      end

    assert events |> Enum.uniq() |> length() > 2
  end

  describe "failures report the response's request ID" do
    test "source", context do
      mount =
        ImagePipe.Plug.init(
          processing_pool: context.pool,
          telemetry_prefix: context.prefix,
          sources: [
            path: [
              adapter: ImagePipe.Source.File,
              match: :path,
              options: [root: "priv/static", root_id: "static"]
            ]
          ]
        )

      conn = request(mount, "w=32", "missing.jpg")

      assert conn.status == 404
      id = response_id(conn)
      assert {_pid, ^id, %{result: :source_error}} = event(context.prefix, [:request])
    end

    test "decode", context do
      conn = request(mount(context, "not an image"), "w=32")

      assert conn.status == 415
      id = response_id(conn)

      assert {_pid, ^id, %{result: :processing_error}} =
               event(context.prefix, [:source, :fetch_decode])

      assert {_pid, ^id, %{result: :processing_error, error: :decode}} =
               event(context.prefix, [:request])
    end

    test "encode", context do
      mount = Keyword.put(mount(context, @image), :image_module, RaisingEncoderImage)

      {conn, _log} = with_log(fn -> request(mount, "w=32/format=jpeg") end)

      assert conn.status == 500
      id = response_id(conn)
      assert {_pid, ^id, %{result: :processing_error}} = event(context.prefix, [:encode])
      assert {_pid, ^id, %{result: :processing_error}} = event(context.prefix, [:request])
    end
  end

  def handle_event(event, _measurements, metadata, test_pid) do
    send(test_pid, {:event, event, self(), Logger.metadata()[:request_id], metadata})
  end

  defp mount(context, bytes, extra \\ []) do
    config =
      ImagePipe.config(
        [
          processing_pool: context.pool,
          telemetry_prefix: context.prefix,
          sources: [
            path: [
              adapter: ProcessingSource,
              match: :path,
              options: [test: self(), bytes: bytes]
            ]
          ]
        ] ++ extra
      )

    ImagePipe.Plug.init(config: config)
  end

  defp request(mount, options, source \\ "ready") do
    conn(:get, "/#{options}/src/#{source}")
    |> Plug.RequestId.call(Plug.RequestId.init([]))
    |> ImagePipe.Plug.call(mount)
  end

  defp response_id(conn) do
    [id] = Plug.Conn.get_resp_header(conn, "x-request-id")
    id
  end

  defp event(prefix, stage) do
    event = prefix ++ stage ++ [:stop]
    assert_received {:event, ^event, pid, id, metadata}
    {pid, id, metadata}
  end
end
