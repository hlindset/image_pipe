defmodule ImagePipe.Request.RunnerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Request.Runner
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved, as: SourceResolved
  alias ImagePipe.Source.Response, as: SourceResponse
  alias ImagePipe.Test.Delivery.SessionProbe
  alias Vix.Vips.Image, as: VipsImage

  defmodule CacheHit do
    @behaviour ImagePipe.Cache

    def get(_key, opts), do: Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    def open_sink(_key, _metadata, _opts), do: raise("cache hit test should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache hit test should not write")
    def commit_sink(_state, _opts), do: raise("cache hit test should not write")

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CacheReadProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      send(self(), {:cache_lookup, key})
      Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    end

    def open_sink(_key, _metadata, _opts), do: raise("cache lookup test should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache lookup test should not write")
    def commit_sink(_state, _opts), do: raise("cache lookup test should not write")
    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CacheHitWriteProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      send(self(), {:cache_lookup, key})
      Keyword.fetch!(opts, :entry) |> then(&{:hit, &1})
    end

    def open_sink(key, metadata, opts),
      do: {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}

    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = entry_from_state(state)
      send(Keyword.get(state.opts, :test_pid, self()), {:cache_put, state.key, entry, state.opts})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok

    defp entry_from_state(state) do
      %ImagePipe.Cache.Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }
    end
  end

  defmodule CacheMissWriteProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      send(self(), {:cache_lookup, key})
      :miss
    end

    def open_sink(key, metadata, opts),
      do: {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}

    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = entry_from_state(state)
      emit(state.opts, {:cache_put, state.key, entry})
      send(Keyword.get(state.opts, :test_pid, self()), {:cache_put, state.key, entry, state.opts})
      :ok
    end

    def abort_sink(state, _opts) do
      emit(state.opts, {:cache_abort, state.key, Enum.reverse(state.chunks)})
      :ok
    end

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end

    defp entry_from_state(state) do
      %ImagePipe.Cache.Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }
    end
  end

  defmodule CacheReadErrorWriteProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      {:error, :read_failed}
    end

    def open_sink(key, metadata, opts),
      do: {:ok, %{key: key, metadata: metadata, chunks: [], opts: opts}}

    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = entry_from_state(state)
      emit(state.opts, {:cache_put, state.key, entry})
      send(Keyword.get(state.opts, :test_pid, self()), {:cache_put, state.key, entry, state.opts})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end

    defp entry_from_state(state) do
      %ImagePipe.Cache.Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }
    end
  end

  defmodule CacheWriteErrorProbe do
    @behaviour ImagePipe.Cache

    def get(key, opts) do
      emit(opts, {:cache_lookup, key})
      :miss
    end

    def open_sink(_key, _metadata, opts), do: {:ok, %{opts: opts}}

    def write_chunk(state, chunk, _opts) do
      emit(state.opts, {:cache_put_attempted, chunk})
      {:error, :write_failed, state}
    end

    def commit_sink(_state, _opts), do: :ok
    def abort_sink(_state, _opts), do: :ok

    defp emit(opts, event) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), event})
        :error -> :ok
      end
    end
  end

  defmodule ClosingAfterFirstChunkAdapter do
    @behaviour Plug.Conn.Adapter

    @impl Plug.Conn.Adapter
    def send_resp(payload, _status, _headers, body), do: {:ok, IO.iodata_to_binary(body), payload}

    @impl Plug.Conn.Adapter
    def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, "", payload}

    @impl Plug.Conn.Adapter
    def send_chunked(payload, _status, _headers), do: {:ok, "", %{payload | chunks: 0}}

    @impl Plug.Conn.Adapter
    def chunk(%{chunks: 0} = payload, body),
      do: {:ok, IO.iodata_to_binary(body), %{payload | chunks: 1}}

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

  defmodule SourceImage do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePipe.Source
    def fetch(_resolved, opts, _runtime_opts) do
      emit(opts)
      body = File.read!("priv/static/images/beach.jpg")
      {:ok, %SourceResponse{stream: [body]}}
    end

    defp emit(opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :source_fetch})
        :error -> :ok
      end
    end
  end

  defmodule SourceBytes do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePipe.Source
    def fetch(_resolved, opts, _runtime_opts) do
      emit(opts)
      {:ok, %SourceResponse{stream: [Keyword.fetch!(opts, :body)]}}
    end

    defp emit(opts) do
      case Keyword.fetch(opts, :test_pid) do
        {:ok, pid} -> send(pid, {:runner_event, Keyword.fetch!(opts, :test_ref), :source_fetch})
        :error -> :ok
      end
    end
  end

  defmodule SourceShouldNotFetch do
    @behaviour ImagePipe.Source

    @impl ImagePipe.Source
    def validate_options(opts), do: {:ok, opts}

    @impl ImagePipe.Source
    def resolve(_source, _opts, _runtime_opts), do: raise("runner tests pass resolved sources")

    @impl ImagePipe.Source
    def fetch(_resolved, _opts, _runtime_opts), do: raise("source should not fetch on cache hit")
  end

  defp plan(overrides \\ []) do
    struct!(
      Plan,
      Keyword.merge(
        [
          source: %SourcePath{segments: ["images", "beach.jpg"]},
          pipelines: [%Pipeline{operations: []}],
          output: %Output{mode: {:explicit, :jpeg}}
        ],
        overrides
      )
    )
  end

  defp resize_fit_operation(width, height) do
    assert {:ok, operation} =
             Operation.resize(
               :fit,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               enlargement: :deny
             )

    operation
  end

  defp resize_cover_operation(width, height, guide) do
    assert {:ok, operation} =
             Operation.resize(
               :cover,
               tagged_resize_dimension(width),
               tagged_resize_dimension(height),
               enlargement: :deny,
               guide: guide
             )

    operation
  end

  defp tagged_resize_dimension(:auto), do: :auto
  defp tagged_resize_dimension(pixels), do: {:px, pixels}

  defp face_assist_crop_operation(width, height) do
    assert {:ok, operation} =
             Operation.crop_guided({:px, width}, {:px, height}, {:smart, :face_assist})

    operation
  end

  defp require_tiff_support! do
    with {:ok, loader_suffixes} <- VipsImage.supported_loader_suffixes(),
         true <- ".tiff" in loader_suffixes,
         {:ok, saver_suffixes} <- VipsImage.supported_saver_suffixes(),
         true <- ".tiff" in saver_suffixes do
      :ok
    else
      _error -> raise ExUnit.AssertionError, message: "TIFF load/save support unavailable"
    end
  end

  defp tiff_body(color, opts \\ []) do
    Image.new!(20, 20, Keyword.merge([color: color], opts))
    |> Image.write!(:memory, suffix: ".tiff")
  end

  defp background_operation(alpha) do
    assert {:ok, color} = Operation.color(255, 255, 255, alpha)
    assert {:ok, operation} = Operation.background(color)
    operation
  end

  defp resolved_source(overrides \\ []) do
    struct!(
      SourceResolved,
      Keyword.merge(
        [
          adapter: :path,
          source_kind: :path,
          identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
          internal_cache: :enabled,
          http_cache: :inherit,
          cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
          fetch: :fixture
        ],
        overrides
      )
    )
  end

  defp assert_cancelled(%PreparedStream{} = prepared) do
    assert :ok = prepared.cancel.()
    assert_session_terminated()
  end

  defp drain_prepared_stream(%PreparedStream{} = prepared) do
    case prepared.next.() do
      {:chunk, chunk} when is_binary(chunk) -> drain_prepared_stream(prepared)
      :done -> :ok
      {:error, reason} -> flunk("expected prepared stream to complete, got #{inspect(reason)}")
    end
  end

  # Affirmative liveness: the session is still there, not merely "no teardown
  # signal has arrived yet".
  defp refute_session_terminated do
    assert SessionProbe.coordinators() != [], "expected a live delivery coordinator"
  end

  defp assert_session_terminated do
    # Monitoring a coordinator that is already dead still delivers a :DOWN, so
    # there is no race with a session that stopped before we looked.
    for coordinator <- SessionProbe.coordinators() do
      ref = Process.monitor(coordinator)
      assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}, 2_000
    end

    assert SessionProbe.coordinators() == []
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp run(conn, %Plan{} = plan, %SourceResolved{} = resolved_source, opts) do
    Runner.run(conn, plan, resolved_source, empty_cache_headers(), request_opts(opts))
  end

  defp run(
         conn,
         %Plan{} = plan,
         %SourceResolved{} = resolved_source,
         %CacheHeaders{} = prepared_http_cache,
         opts
       ) do
    Runner.run(conn, plan, resolved_source, prepared_http_cache, request_opts(opts))
  end

  defp request_opts(opts) do
    Keyword.merge(
      [
        max_body_bytes: 10_000_000,
        max_input_pixels: 40_000_000,
        max_result_width: 8_192,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      ],
      opts
    )
  end

  defp empty_cache_headers do
    %CacheHeaders{representation_headers: [], headers: [], etag: nil}
  end

  defp attach_telemetry(events) do
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  test "source-only opaque TIFF automatic output falls back to JPEG after transforms" do
    require_tiff_support!()

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body(:white)}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_cancelled(prepared)
  end

  test "source-only alpha TIFF automatic output falls back to PNG after transforms" do
    require_tiff_support!()

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :png, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_cancelled(prepared)
  end

  test "opaque background transform removes alpha before source-only fallback" do
    require_tiff_support!()

    plan =
      plan(
        pipelines: [%Pipeline{operations: [background_operation({:ratio, 1, 1})]}],
        output: %Output{mode: :automatic}
      )

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/bg:fff/plain/images/source.tiff"),
               plan,
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_cancelled(prepared)
  end

  test "modern Accept candidate still wins for source-only input before final alpha fallback" do
    require_tiff_support!()

    conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/webp")

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               sources: %{path: {SourceBytes, body: tiff_body([255, 255, 255, 128])}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :webp, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_cancelled(prepared)
  end

  test "source-only automatic fallback cache miss writes JPEG entry with Vary" do
    require_tiff_support!()
    ref = make_ref()

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{
                 path: {SourceBytes, body: tiff_body(:white), test_pid: self(), test_ref: ref}
               }
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :jpeg, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, ^key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/jpeg", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
    assert_session_terminated()
  end

  test "source-only alpha fallback cache miss writes PNG entry with Vary" do
    require_tiff_support!()
    ref = make_ref()

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{
                 path:
                   {SourceBytes,
                    body: tiff_body([255, 255, 255, 128]), test_pid: self(), test_ref: ref}
               }
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :png, response_headers: [{"vary", "Accept"}]}
           } = prepared

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, ^key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:cache_put, ^key,
                     %Entry{content_type: "image/png", headers: [{"vary", "Accept"}]}, _opts}

    refute_received {:cache_lookup, _second_key}
    assert_session_terminated()
  end

  test "source-only automatic cache hit returns cached entry without fetching source" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/_/plain/images/source.tiff"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheHit, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )
  end

  test "source-only automatic cache lookup normalizes non-modern Accept headers" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    png_conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/png")

    jpeg_q0_conn =
      :get
      |> conn("/_/plain/images/source.tiff")
      |> Plug.Conn.put_req_header("accept", "image/jpeg;q=0")

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               png_conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, png_key}

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               jpeg_q0_conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, jpeg_q0_key}
    assert png_key == jpeg_q0_key
    assert png_key.data[:output][:modern_candidates] == []
  end

  test "explicit cache hit returns a cache-entry delivery without processing origin" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok,
            {:cache_entry, ^entry, %Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(),
               resolved_source(),
               cache: {CacheHit, entry: entry}
             )
  end

  test "cache hit delivery carries prepared HTTP cache value" do
    prepared_http_cache = %CacheHeaders{
      representation_headers: [],
      headers: [{"cache-control", "public, max-age=31536000, immutable"}],
      etag: nil
    }

    entry = %Entry{
      body: "cached",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok,
            {:cache_entry, ^entry, %Response{}, ^prepared_http_cache,
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/image"),
               plan(),
               resolved_source(),
               prepared_http_cache,
               cache: {CacheHit, entry: entry}
             )
  end

  test "automatic cache hit returns without resolving source format" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [{"vary", "Accept"}],
      created_at: DateTime.utc_now()
    }

    conn =
      :get
      |> conn("/_/plain/images/beach.jpg")
      |> Plug.Conn.put_req_header("accept", "image/jpeg")

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn,
               plan(output: %Output{mode: :automatic}),
               resolved_source(),
               cache: {CacheHit, entry: entry}
             )
  end

  test "semantic resize auto cache hit does not fetch source or resolve operations" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/beach.jpg"),
               plan(pipelines: [%Pipeline{operations: [operation]}]),
               resolved_source(
                 identity: [
                   kind: :path,
                   root: "test",
                   path: ["images", "beach.jpg"],
                   revision: "1"
                 ]
               ),
               cache: {CacheReadProbe, entry: entry},
               sources: %{path: {SourceShouldNotFetch, []}}
             )

    assert_received {:cache_lookup, key}

    assert key.data[:source_identity] == [
             kind: :path,
             root: "test",
             path: ["images", "beach.jpg"],
             revision: "1"
           ]

    assert [[operation_data]] = key.data[:pipelines]
    assert operation_data[:op] == :resize
    assert operation_data[:mode] == :auto
    serialized_data = inspect(key.data, limit: :infinity)
    refute serialized_data =~ "selected_branch"
    refute serialized_data =~ "source_width"
    refute serialized_data =~ "source_height"
  end

  test "cache miss executes semantic plan after fetch and stores under original key" do
    ref = make_ref()

    assert {:ok, operation} =
             Operation.resize(:auto, {:px, 100}, {:px, 100},
               dpr: 1.0,
               enlargement: :deny
             )

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/rt:auto/w:100/h:100/f:jpeg/plain/images/beach.jpg"),
               plan(
                 pipelines: [%Pipeline{operations: [operation]}],
                 resolver: ImagePipe.Transform.NeutralResolver
               ),
               resolved_source(),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, test_pid: self(), test_ref: ref}}
             )

    assert %PreparedStream{} = prepared

    assert_receive {:runner_event, ^ref, first_event}
    assert {:cache_lookup, key} = first_event
    assert_receive {:runner_event, ^ref, second_event}
    assert second_event == :source_fetch
    refute_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{}}}

    assert_received {:cache_lookup, key}
    assert :ok = drain_prepared_stream(prepared)
    assert_received {:cache_put, ^key, %Entry{}, _opts}
    refute_received {:cache_lookup, _second_key}
    assert_session_terminated()
  end

  test "no-cache explicit output returns a prepared stream delivery" do
    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               sources: %{path: {SourceImage, []}}
             )

    assert is_binary(prepared.first_chunk)
    assert byte_size(prepared.first_chunk) > 0
    assert prepared.content_type == "image/jpeg"
    assert is_function(prepared.next, 0)
    assert is_function(prepared.cancel, 0)

    refute_session_terminated()
    assert_cancelled(prepared)
  end

  test "cache-skip explicit output returns a prepared stream delivery even when cache is configured" do
    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :disabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: make_ref()},
               sources: %{path: {SourceImage, []}}
             )

    refute_received {:cache_lookup, _key}
    refute_received {:cache_put, _key, _entry, _opts}

    refute_session_terminated()
    assert_cancelled(prepared)
  end

  test "configured cache miss writes cache after successful prepared stream delivery" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    refute_received {:cache_put, _key, _entry, _opts}
    refute_session_terminated()

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.status == 200
    assert is_binary(conn.resp_body)
    assert byte_size(conn.resp_body) > 0

    assert_received {:runner_event, ^ref,
                     {:cache_put, ^key, %Entry{content_type: "image/jpeg", body: body}}}

    assert is_binary(body)
    assert byte_size(body) > 0
    assert_session_terminated()
  end

  test "cache read fail-open miss returns a prepared stream and writes cache after successful drain" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheReadErrorWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:runner_event, ^ref, {:cache_lookup, key}}
    refute_received {:runner_event, ^ref, {:cache_put, _key, %Entry{}}}
    refute_session_terminated()

    assert :ok = drain_prepared_stream(prepared)

    assert_received {:runner_event, ^ref, {:cache_put, ^key, %Entry{content_type: "image/jpeg"}}}
    assert_session_terminated()
  end

  test "streamed cache miss does not write cache when the client closes before done" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {ClosingAfterFirstChunkAdapter, %{chunks: nil}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    refute Map.has_key?(conn.private, :image_pipe_send_result)
    assert_received {:cache_lookup, _key}
    assert_received {:runner_event, ^ref, {:cache_abort, _key, chunks}}
    assert chunks != []
    refute_received {:cache_put, _key, _entry, _opts}
    assert_session_terminated()
  end

  test "streamed cache miss does not write cache when send_chunked fails" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FailingChunkedAdapter, %{}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.private.image_pipe_send_result == :processing_error
    assert_received {:cache_lookup, _key}
    assert_received {:runner_event, ^ref, {:cache_abort, _key, chunks}}
    assert chunks != []
    refute_received {:cache_put, _key, _entry, _opts}
    assert_session_terminated()
  end

  test "streamed cache miss does not write cache when the first chunk fails" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    conn =
      :get
      |> conn("/image")
      |> Map.put(:adapter, {FirstChunkClosedAdapter, %{}})
      |> Sender.send_result(
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    refute Map.has_key?(conn.private, :image_pipe_send_result)
    assert_received {:cache_lookup, _key}
    assert_received {:runner_event, ^ref, {:cache_abort, _key, chunks}}
    assert chunks != []
    refute_received {:cache_put, _key, _entry, _opts}
    assert_session_terminated()
  end

  test "streamed cache miss staging write errors fail open" do
    attach_telemetry([[:image_pipe, :cache, :stage]])
    ref = make_ref()

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/plain/images/beach.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               cache: {CacheWriteErrorProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    conn =
      Sender.send_result(
        conn(:get, "/image"),
        {:ok, {:prepared_stream, prepared, response, empty_cache_headers()}},
        []
      )

    assert conn.status == 200
    refute Map.get(conn.private, :image_pipe_send_result) == :processing_error
    assert_received {:runner_event, ^ref, {:cache_put_attempted, chunk}}
    assert is_binary(chunk)
    assert_session_terminated()

    assert_receive {:telemetry_event, [:image_pipe, :cache, :stage], _measurements,
                    %{result: :cache_error, cache: :stage_error, error: :write_failed}}
  end

  test "streamed automatic cache miss writes negotiated entry with Vary" do
    ref = make_ref()

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/f:auto/plain/images/beach.jpg", "")
               |> Plug.Conn.put_req_header("accept", "image/webp,image/jpeg;q=0.8"),
               plan(output: %Output{mode: :automatic}),
               resolved_source(internal_cache: :enabled),
               cache: {CacheMissWriteProbe, test_pid: self(), test_ref: ref},
               sources: %{path: {SourceImage, []}}
             )

    assert %PreparedStream{} = prepared

    assert_received {:cache_lookup, key}
    assert :ok = drain_prepared_stream(prepared)

    assert_received {:runner_event, ^ref,
                     {:cache_put, ^key,
                      %Entry{
                        body: body,
                        content_type: content_type,
                        headers: [{"vary", "Accept"}]
                      }}}

    assert is_binary(body)
    assert content_type in ["image/webp", "image/jpeg"]
    assert_session_terminated()
  end

  test "no-cache decode failure returns a pre-response processing error and removes the session" do
    assert {:error, {:processing, {:decode, _reason}, _headers}} =
             run(
               conn(:get, "/_/plain/images/not-image.jpg"),
               plan(),
               resolved_source(internal_cache: :enabled),
               body: "not an image",
               sources: %{path: {SourceBytes, body: "not an image"}}
             )

    assert_session_terminated()
  end

  test "multiple pipelines reach processing" do
    plan =
      plan(
        pipelines: [
          %Pipeline{operations: [resize_fit_operation(100, :auto)]},
          %Pipeline{operations: [resize_fit_operation(80, :auto)]}
        ]
      )

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               sources: %{path: {SourceImage, []}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{format: :jpeg, quality: :default, response_headers: []}
           } = prepared

    assert_cancelled(prepared)
  end

  test "resolved output carries effective explicit quality" do
    plan =
      plan(
        output: %Output{
          mode: {:explicit, :webp},
          quality: :default,
          format_qualities: %{webp: {:quality, 70}}
        }
      )

    assert {:ok, {:prepared_stream, prepared, %Response{}, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/f:webp/fq:webp:70/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               sources: %{path: {SourceImage, []}}
             )

    assert %PreparedStream{
             resolved_output: %Resolved{
               format: :webp,
               quality: {:quality, 70},
               response_headers: []
             }
           } = prepared

    assert_cancelled(prepared)
  end

  test "known plan operations are included in cache lookup key data" do
    operations = [resize_cover_operation(100, 100, {:anchor, :left, :top})]

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = plan(pipelines: [%Pipeline{operations: operations}])

    assert {:ok,
            {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
             %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan,
               resolved_source(),
               cache: {CacheReadProbe, entry: entry}
             )

    assert_received {:cache_lookup, key}

    assert key.data[:pipelines] == [
             [
               [
                 op: :resize,
                 mode: :cover,
                 width: [unit: :logical_px, value: 100],
                 height: [unit: :logical_px, value: 100],
                 dpr: [unit: :ratio, numerator: 1, denominator: 1],
                 enlargement: :deny,
                 guide: [type: :anchor, x: :left, y: :top],
                 x_offset: {:pixels, 0.0},
                 y_offset: {:pixels, 0.0},
                 min_width: nil,
                 min_height: nil,
                 max_width: nil,
                 max_height: nil,
                 max_area: nil,
                 zoom_x: 1.0,
                 zoom_y: 1.0
               ]
             ]
           ]
  end

  test "cache hits and misses carry plan response delivery metadata" do
    response = %ImagePipe.Plan.Response{
      disposition: :attachment,
      filename: "carried"
    }

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, ^response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               sources: %{path: {SourceImage, []}}
             )

    assert_cancelled(prepared)

    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    assert {:ok,
            {:cache_entry, ^entry, ^response, %CacheHeaders{}, %{cache_key: _, cache_serve_us: _}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHit, entry: entry}
             )
  end

  test "face-assist cache lookup injects detector identity into the key" do
    entry = %Entry{
      body: "cached jpeg",
      content_type: "image/jpeg",
      headers: [],
      created_at: DateTime.utc_now()
    }

    plan = plan(pipelines: [%Pipeline{operations: [face_assist_crop_operation(200, 100)]}])

    run_lookup = fn fake_identity ->
      opts =
        Runner.with_detector_identity(
          [
            cache: {CacheReadProbe, entry: entry},
            detector: ImagePipe.Test.FakeDetector,
            identity: fake_identity
          ],
          plan
        )

      assert {:ok,
              {:cache_entry, ^entry, %ImagePipe.Plan.Response{}, %CacheHeaders{},
               %{cache_key: _, cache_serve_us: _}}} =
               run(
                 conn(:get, "/_/g:sm/w:200/h:100/f:jpeg/plain/images/beach.jpg"),
                 plan,
                 resolved_source(),
                 opts
               )

      assert_received {:cache_lookup, key}
      key
    end

    key_v1 = run_lookup.(:v1)
    key_v2 = run_lookup.(:v2)

    assert key_v1.data[:detector] == {ImagePipe.Test.FakeDetector, :v1}
    refute key_v1.hash == key_v2.hash
  end

  test "invalid cache hit content type fails open and refreshes through prepared stream" do
    invalid_entry = %Entry{
      body: "cached gif",
      content_type: "image/gif",
      headers: [],
      created_at: DateTime.utc_now()
    }

    response = %ImagePipe.Plan.Response{
      disposition: :inline,
      filename: "report"
    }

    assert {:ok, {:prepared_stream, %PreparedStream{} = prepared, ^response, %CacheHeaders{}}} =
             run(
               conn(:get, "/_/f:jpeg/plain/images/beach.jpg"),
               plan(response: response),
               resolved_source(),
               cache: {CacheHitWriteProbe, entry: invalid_entry, test_pid: self()},
               sources: %{path: {SourceImage, []}}
             )

    assert_received {:cache_lookup, key}
    refute_received {:cache_put, _key, _entry, _opts}

    assert :ok = drain_prepared_stream(prepared)
    assert_received {:cache_put, ^key, %Entry{content_type: "image/jpeg"}, _opts}
    refute_received {:cache_lookup, _another_key}
    assert_session_terminated()
  end
end
