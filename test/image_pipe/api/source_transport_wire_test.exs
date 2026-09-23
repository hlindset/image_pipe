defmodule ImagePipe.API.SourceTransportWireTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.HTTP
  alias ImagePipe.Test.RawSourceOrigin

  @moduletag capture_log: true

  test "an unready HTTP2-only pool returns a safe upstream failure" do
    origin = start_supervised!({RawSourceOrigin, test_pid: self(), response: "", finish: :stall})
    assert_receive {:origin_ready, ^origin, url}
    url = String.replace_prefix(url, "http:", "https:")
    prefix = [__MODULE__, :http2_startup]
    event = prefix ++ [:source, :fetch, :stop]
    ref = :telemetry_test.attach_event_handlers(self(), [event])
    on_exit(fn -> :telemetry.detach(ref) end)

    opts =
      ImagePipe.Plug.init(
        telemetry_prefix: prefix,
        sources: [
          url:
            {HTTP,
             allowed_hosts: ["127.0.0.1"],
             address_policy: [allow_loopback: true],
             req_options: [connect_options: [protocols: [:http2], timeout: 200]]}
        ]
      )

    conn = Plug.Test.conn(:get, "/format=png/src/#{url}/private.jpg") |> ImagePipe.Plug.call(opts)
    assert conn.status == 404
    assert_receive {^event, ^ref, _, %{result: :source_error, error: :connect_error} = metadata}
    refute inspect(metadata) =~ "private.jpg"
  end

  for {name, response, finish, status, reason} <- [
        {:truncated, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\nshort", :close, 502,
         :truncated_body},
        {:timeout, "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n", :stall, 504,
         :receive_timeout},
        {:framing, "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\nnot-hex\r\n", :close,
         422, :invalid_body}
      ] do
    test "#{name} origin failure retains its status and safe telemetry" do
      origin =
        start_supervised!(
          {RawSourceOrigin,
           test_pid: self(), response: unquote(response), finish: unquote(finish)}
        )

      assert_receive {:origin_ready, ^origin, url}
      prefix = [__MODULE__, unquote(name)]
      handler = make_ref()
      event = prefix ++ [:source, :fetch_decode, :stop]

      :ok =
        :telemetry.attach(
          handler,
          event,
          fn event, _measurements, metadata, pid -> send(pid, {event, metadata}) end,
          self()
        )

      on_exit(fn -> :telemetry.detach(handler) end)

      opts =
        ImagePipe.Plug.init(
          telemetry_prefix: prefix,
          sources: [
            url:
              {HTTP,
               allowed_hosts: ["127.0.0.1"],
               address_policy: [allow_loopback: true],
               receive_timeout: if(unquote(finish) == :stall, do: 100, else: 5_000)}
          ]
        )

      conn =
        Plug.Test.conn(:get, "/format=png/src/#{url}/secret.jpg") |> ImagePipe.Plug.call(opts)

      assert conn.status == unquote(status)
      assert_receive {^event, metadata}
      assert metadata.result == :source_error
      assert metadata.error == unquote(reason)
      refute inspect(metadata) =~ "secret.jpg"
    end
  end
end
