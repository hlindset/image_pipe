defmodule ImagePipe.API.CacheTelemetryPrefixTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.Caches

  @moduletag :tmp_dir

  test "the cache's own events carry the instance's telemetry prefix", %{tmp_dir: root} do
    prefix = [:cache_telemetry_prefix_test]
    handler = {__MODULE__, make_ref()}
    test = self()

    :ok =
      :telemetry.attach_many(
        handler,
        [prefix ++ [:cache, :admission, :stop]],
        fn event, _measurements, _metadata, _config -> send(test, {:event, event}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    body = Image.new!(64, 48, color: :red) |> Image.write!(:memory, suffix: ".png")
    origin = fn conn -> Plug.Conn.send_resp(conn, 200, body) end

    opts =
      Caches.start!(
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [root_url: "http://origin.test", req_options: [plug: origin]]
          ]
        ],
        cache: [root: Path.join(root, "output"), max_size_bytes: 1_000_000],
        telemetry_prefix: prefix
      )

    conn = conn(:get, "/w=20/format=png/src/image") |> ImagePipe.Plug.call(Caches.plug(opts))
    assert conn.status == 200
    Caches.await_writes(opts)

    # Admission, which also reports evictions, runs in the cache's process.
    assert_received {:event, [:cache_telemetry_prefix_test, :cache, :admission, :stop]}
  end
end
