defmodule ImagePipe.API.OperationExecutionWireTest do
  use ExUnit.Case, async: true

  import Plug.Test

  setup %{test: test} do
    prefix = [__MODULE__, test]
    handler = {__MODULE__, prefix}
    events = for kind <- [:start, :stop], do: prefix ++ [:transform, :operation, kind]
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler,
        events,
        fn event, _measurements, metadata, _ ->
          send(test_pid, {List.last(event), metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    config =
      ImagePipe.Plug.init(
        telemetry_prefix: prefix,
        sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "operations"}]
      )

    %{config: config, prefix: prefix}
  end

  test "operations follow stage and group order and expose their parameters", %{config: config} do
    conn =
      conn(:get, "/gray/blur=1/-/brightness=20/format=png/src/images/beach.jpg")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 200

    for name <- [:blur, :gray, :brightness] do
      assert_receive {kind, metadata}
      assert kind == :start
      assert %{operation: ^name, params: params} = metadata
      assert is_struct(params)
      refute Map.has_key?(metadata, :index)
      assert_receive {kind, metadata}
      assert kind == :stop
      assert %{operation: ^name, result: :ok, dims: {width, height}} = metadata
      assert width > 0 and height > 0
    end

    refute_received {:start, _}
  end

  test "an out-of-bounds region returns 400 and stops later operations", %{config: config} do
    conn =
      conn(:get, "/region=99999,99999,10,10/blur=1/-/gray/src/images/beach.jpg")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 400
    assert conn.resp_body == "requested region is outside the image"
    assert_receive {:start, %{operation: :crop}}
    assert_receive {:stop, %{operation: :crop, result: :error}}
    refute_received {:start, _}
  end

  test "a mid-operation materialization failure returns 415 and stops execution", %{
    prefix: prefix
  } do
    body = "priv/static/images/beach.jpg" |> File.read!() |> binary_part(0, 5000)

    origin = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("image/jpeg")
      |> Plug.Conn.send_resp(200, body)
    end

    config =
      ImagePipe.Plug.init(
        telemetry_prefix: prefix,
        sources: [
          path:
            {ImagePipe.SourceTest.RootHTTPAdapter,
             root_url: "http://origin.test", req_options: [plug: origin]}
        ]
      )

    conn =
      conn(:get, "/crop=20,10/anchor=smart/blur=1/src/images/beach.jpg")
      |> ImagePipe.Plug.call(config)

    assert conn.status == 415
    assert conn.resp_body == "source response is not a supported image"
    assert_receive {:start, %{operation: :crop}}
    assert_receive {:stop, %{operation: :crop, result: :error}}
    refute_received {:start, _}
  end
end
