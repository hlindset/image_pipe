defmodule ImagePipe.Response.SenderTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan.Response
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Response.Sender

  defmodule ClosingChunkAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", %{payload | chunks: 0}}

    @impl Plug.Conn.Adapter
    def chunk(%{chunks: 0} = payload, body) do
      {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}
    end

    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FailingChunkedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(_payload, _status, _headers), do: raise("chunked open failed")

    @impl Plug.Conn.Adapter
    def chunk(payload, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  defmodule FirstChunkClosedAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def chunk(_payload, _body), do: {:error, :closed}

    @impl Plug.Conn.Adapter
    def read_req_body(payload, _opts), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def inform(payload, _status, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def push(payload, _path, _headers), do: {:ok, payload}

    @impl Plug.Conn.Adapter
    def get_peer_data(_payload), do: %Plug.Conn.Unfetched{aspect: :peer_data}

    @impl Plug.Conn.Adapter
    def get_http_protocol(_payload), do: :"HTTP/1.1"

    @impl Plug.Conn.Adapter
    def upgrade(payload, _protocol, _opts), do: {:ok, payload}
  end

  test "cache hits apply content disposition from plan response" do
    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %Response{disposition: :attachment, filename: "report"}

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok,
         {:cache_entry, entry, response, empty_cache_headers(),
          %{cache_key: "ip-cache-key", cache_serve_us: 0}}},
        []
      )

    assert conn.status == 200

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(attachment; filename="report.webp")]
  end

  test "cache hits merge generated headers before cached entry headers" do
    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [{"cache-control", "public, max-age=60"}, {"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    prepared = %CacheHeaders{
      representation_headers: [{"vary", "Accept"}],
      headers: [
        {"cache-control", "public, max-age=31536000, immutable"},
        {"etag", ~s("ip1-test")}
      ],
      etag: ~s("ip1-test")
    }

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok,
         {:cache_entry, entry, %Response{}, prepared,
          %{cache_key: "ip-cache-key", cache_serve_us: 0}}},
        []
      )

    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert Plug.Conn.get_resp_header(conn, "etag") == [~s("ip1-test")]
    assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept"]
    assert conn.status == 200
  end

  test "current host cache-control wins over generated and cached headers" do
    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    prepared = %CacheHeaders{
      representation_headers: [],
      headers: [{"cache-control", "public, max-age=31536000, immutable"}],
      etag: nil
    }

    conn =
      :get
      |> conn("/image")
      |> Plug.Conn.put_resp_header("cache-control", "private, max-age=30")
      |> Sender.send_result(
        {:ok,
         {:cache_entry, entry, %Response{}, prepared,
          %{cache_key: "ip-cache-key", cache_serve_us: 0}}},
        []
      )

    assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=30"]
  end

  test "prepared streams merge generated headers before stream headers" do
    prepared_stream =
      prepared_stream(headers: [{"cache-control", "public, max-age=60"}])

    prepared = %CacheHeaders{
      representation_headers: [],
      headers: [{"cache-control", "public, max-age=31536000, immutable"}],
      etag: nil
    }

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared_stream, %Response{}, prepared}},
        []
      )

    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]
  end

  test "cache hit header telemetry is low-cardinality" do
    attach_telemetry([[:image_pipe, :http_cache, :cache_hit, :headers]])

    entry = %Entry{
      body: "body",
      content_type: "image/webp",
      headers: [],
      created_at: DateTime.utc_now()
    }

    prepared = %CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-token")}],
      etag: ~s("ip1-token")
    }

    _conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok,
         {:cache_entry, entry, %Response{}, prepared,
          %{cache_key: "ip-cache-key", cache_serve_us: 0}}},
        []
      )

    assert_receive {:telemetry_event, [:image_pipe, :http_cache, :cache_hit, :headers], %{},
                    metadata}

    assert metadata == %{
             etag: true,
             generated_cache_headers: true,
             representation_headers: false
           }
  end

  test "prepared streams send first chunk and pull later chunks" do
    parent = self()
    response = %Response{disposition: :inline, filename: "prepared"}
    next_ref = make_ref()
    replies = start_supervised!({Agent, fn -> [{:chunk, "second"}, :done] end})

    next = fn ->
      send(parent, {next_ref, :next})

      Agent.get_and_update(replies, fn [reply | rest] -> {reply, rest} end)
    end

    prepared =
      prepared_stream(
        first_chunk: "first",
        headers: [{"content-disposition", ~s(inline; filename="prepared.jpg")}],
        next: next
      )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.status == 200
    assert conn.resp_body == "firstsecond"
    assert_received {^next_ref, :next}
    assert_received {^next_ref, :next}

    assert [content_type] = Plug.Conn.get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "image/jpeg")

    assert Plug.Conn.get_resp_header(conn, "content-disposition") ==
             [~s(inline; filename="prepared.jpg")]
  end

  test "prepared streams are not cancelled after normal completion" do
    parent = self()
    cancel_ref = make_ref()
    response = %Response{}

    prepared =
      prepared_stream(
        next: fn -> :done end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.status == 200
    refute_received ^cancel_ref
  end

  test "prepared streams cancel when next returns an error" do
    parent = self()
    cancel_ref = make_ref()
    response = %Response{}

    attach_telemetry([[:image_pipe, :deliver, :stop]])

    prepared =
      prepared_stream(
        next: fn -> {:error, {:encode, :failed_after_first_chunk}} end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.status == 200
    assert conn.private.image_pipe_send_result == :processing_error
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_pipe, :deliver, :stop], _measurements,
                    %{
                      result: :processing_error,
                      stream_phase: :encode,
                      error: :failed_after_first_chunk,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when client closes during later chunk" do
    parent = self()
    cancel_ref = make_ref()

    attach_telemetry([[:image_pipe, :deliver, :stop]])

    prepared =
      prepared_stream(
        next: fn -> {:chunk, "second"} end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {ClosingChunkAdapter, %{chunks: nil}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, %Response{}, empty_cache_headers()}},
        []
      )

    refute Map.has_key?(conn.private, :image_pipe_send_result)
    assert conn.resp_body == "first"
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_pipe, :deliver, :stop], _measurements,
                    %{
                      result: :client_closed,
                      stream_phase: :client,
                      error: :client_closed,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when send_chunked fails" do
    parent = self()
    cancel_ref = make_ref()

    attach_telemetry([[:image_pipe, :deliver, :stop]])

    prepared =
      prepared_stream(
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, %Response{}, empty_cache_headers()}},
        []
      )

    assert conn.private.image_pipe_send_result == :processing_error
    assert_receive ^cancel_ref

    assert_receive {:telemetry_event, [:image_pipe, :deliver, :stop], _measurements,
                    %{
                      result: :processing_error,
                      stream_phase: :encode,
                      error: :error,
                      status: 200,
                      output_format: :jpeg
                    }}
  end

  test "prepared streams cancel when first chunk fails" do
    parent = self()
    cancel_ref = make_ref()

    prepared =
      prepared_stream(
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, %Response{}, empty_cache_headers()}},
        []
      )

    refute Map.has_key?(conn.private, :image_pipe_send_result)
    assert_receive ^cancel_ref
  end

  test "prepared streams cancel when the next callback exits" do
    parent = self()
    cancel_ref = make_ref()

    prepared =
      prepared_stream(
        next: fn -> exit(:session_down) end,
        cancel: fn ->
          send(parent, cancel_ref)
          :ok
        end
      )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, %Response{}, empty_cache_headers()}},
        []
      )

    assert conn.private.image_pipe_send_result == :processing_error
    assert_receive ^cancel_ref
  end

  # Telemetry handlers run synchronously in the emitting process, but the handler
  # table is global. Under `async: true`, concurrent modules that emit
  # `[:image_pipe, :deliver, :stop]` (e.g. full-request telemetry tests) would
  # otherwise have this handler fire and deliver their events into this test's
  # mailbox, contaminating `assert_receive`. Forward only events this test
  # emitted itself: `self() == test_pid` holds exactly for in-process emissions.
  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    if self() == test_pid do
      send(test_pid, {:telemetry_event, event, measurements, metadata})
    end

    :ok
  end

  defp prepared_stream(overrides) do
    struct!(
      PreparedStream,
      Keyword.merge(
        [
          first_chunk: "first",
          content_type: "image/jpeg",
          headers: [],
          next: fn -> :done end,
          cancel: fn -> :ok end,
          resolved_output: %Resolved{
            format: :jpeg,
            quality: :default,
            response_headers: [],
            strip_metadata: true,
            keep_copyright: true,
            color_profile: :strip
          }
        ],
        overrides
      )
    )
  end

  defp empty_cache_headers do
    %CacheHeaders{representation_headers: [], headers: [], etag: nil}
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
