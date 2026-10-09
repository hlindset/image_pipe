defmodule ImagePipe.CacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Resolved

  setup do
    root = Path.join(System.tmp_dir!(), "cache-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    on_exit(fn ->
      for dir <- [root | Path.wildcard(Path.join(root, "**"))],
          File.dir?(dir),
          do: File.chmod(dir, 0o700)

      File.rm_rf(root)
    end)

    %{root: root}
  end

  defp cache_key do
    %Key{
      hash: String.duplicate("a", 64),
      data: [schema_version: 2]
    }
  end

  # Every init case below differs only in `cache:`.
  defp mount(extra) do
    [
      sources: [
        path: [
          adapter: ImagePipe.Source.File,
          match: :path,
          options: [root: "priv/static", root_id: "static"]
        ]
      ]
    ] ++ extra
  end

  defp resolved_output do
    %Resolved{
      format: :webp,
      quality: nil,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end

  test "lookup telemetry tells response lookups from source record lookups", %{root: root} do
    prefix = [__MODULE__, :lookup_entry_kind]
    handler = make_ref()
    event = prefix ++ [:cache, :lookup, :stop]

    :telemetry.attach(
      handler,
      event,
      fn _, _, meta, pid -> send(pid, {:lookup, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    opts = [cache: [root: root], telemetry_prefix: prefix]
    key = cache_key()

    assert {:miss, ^key} = Cache.lookup_entry(key, opts)
    assert_received {:lookup, %{entry: :response, cache_key: hash}}
    assert hash == key.hash

    assert Cache.source_record(key, opts) == nil
    assert_received {:lookup, %{entry: :source_record, cache_key: record_hash}}
    refute record_hash == key.hash
  end

  test "ImagePipe init rejects invalid cache config early", %{root: root} do
    for cache <- [
          {FileSystem, [root: root]},
          [root: root, max_body_bytes: "10MB"]
        ] do
      assert_raise ArgumentError, ~r/invalid cache config/, fn ->
        ImagePipe.Plug.init(mount(cache: cache))
      end
    end
  end

  test "ImagePipe init rejects header/cookie cache partitioning options", %{root: root} do
    for key <- [:key_headers, :key_cookies] do
      assert_raise ArgumentError, ~r/#{key} was removed.*storage_inputs:/s, fn ->
        ImagePipe.Plug.init(mount(cache: [{:root, root}, {key, ["accept-language"]}]))
      end
    end
  end

  test "ImagePipe init rejects invalid filesystem cache options early" do
    for cache <- [
          [root: "relative/cache"],
          [root: System.tmp_dir!(), path_prefix: "../outside"],
          [root: System.tmp_dir!(), path_prefix: "processed//images"]
        ] do
      assert_raise ArgumentError, ~r/invalid cache config/, fn ->
        ImagePipe.Plug.init(mount(cache: cache))
      end
    end
  end

  test "ImagePipe init rejects cache pools whose roots overlap" do
    root = Path.join(System.tmp_dir!(), "image_pipe_overlapping_roots")

    for {output, input} <- [
          {root, root},
          {root, Path.join(root, "input")},
          {Path.join(root, "output"), root},
          {root <> "/", root <> "/../image_pipe_overlapping_roots"}
        ] do
      assert_raise ArgumentError, ~r/cache_pools_require_separate_roots/, fn ->
        ImagePipe.Plug.init(
          mount(
            cache: [root: output],
            input_cache: [root: input]
          )
        )
      end
    end

    assert ImagePipe.Plug.init(
             mount(
               cache: [root: Path.join(root, "output")],
               input_cache: [root: Path.join(root, "output-input")]
             )
           )
  end

  test "ImagePipe init preserves normalized filesystem cache options" do
    root = Path.join(System.tmp_dir!(), "image_pipe_cache_init")

    opts =
      ImagePipe.Plug.init(mount(cache: [root: root <> "/../image_pipe_cache_init"]))

    assert cache_opts = Keyword.fetch!(opts, :cache)
    assert cache_opts[:root] == Path.expand(root)
    assert cache_opts[:path_prefix] == ""
  end

  test "open_sink records cost_us from opts with the stored entry", %{root: root} do
    opts = cache_opts(root, cost_us: 42_000)

    cache_key()
    |> Cache.open_sink(resolved_output(), opts)
    |> Cache.write_chunk("abc", opts)
    |> Cache.commit_sink(opts)

    {:ok, %{meta_path: meta_path}} = FileSystem.paths(cache_key(), Keyword.fetch!(opts, :cache))
    assert {:ok, %{cost_us: 42_000}, _mtime} = FileSystem.read_descriptor(meta_path)
  end

  test "a stored entry carries the resolved output's content type and cacheable headers", %{
    root: root
  } do
    resolved_output = %Resolved{
      format: :webp,
      quality: nil,
      response_headers: [{"Vary", "Accept"}, {"x-private", "drop"}],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }

    opts = cache_opts(root)

    cache_key()
    |> Cache.open_sink(resolved_output, opts)
    |> Cache.write_chunk("abc", opts)
    |> Cache.commit_sink(opts)

    assert {:hit, %Entry{} = entry} = Cache.lookup_entry(cache_key(), opts)
    Entry.close(entry)
    assert entry.content_type == "image/webp"
    assert entry.headers == [{"vary", "Accept"}]
    assert %DateTime{} = entry.created_at
    assert entry.representation == {:image, :webp}
  end

  test "write_chunk and commit_sink store the chunks in order", %{root: root} do
    opts = cache_opts(root)

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), opts)
      |> Cache.write_chunk("abc", opts)
      |> Cache.write_chunk("def", opts)

    assert :ok = Cache.commit_sink(sink, opts)

    assert {:hit, %Entry{body: "abcdef"}} =
             FileSystem.get(cache_key(), Keyword.fetch!(opts, :cache))
  end

  test "abort_sink discards the staged entry and returns ok", %{root: root} do
    opts = cache_opts(root)

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), opts)
      |> Cache.write_chunk("abc", opts)

    assert :ok = Cache.abort_sink(sink, :cancelled, opts)
    assert {:miss, %Key{}} = Cache.lookup_entry(cache_key(), opts)
    assert stored_files(root) == []
  end

  test "open_sink fails open and logs errors", %{root: root} do
    prefix = attach_telemetry([[:cache, :stage]])
    opts = cache_opts(root, telemetry_prefix: prefix)
    File.chmod!(root, 0o500)

    log =
      capture_log(fn ->
        assert Cache.open_sink(cache_key(), resolved_output(), opts) == nil
      end)

    assert log =~ "cache sink open error"

    assert_receive {:telemetry_event, _event, _measurements,
                    %{cache: :stage_error, result: :cache_error, output_format: :webp}}
  end

  test "write_chunk drops the sink when max_body_bytes would be crossed", %{root: root} do
    prefix = attach_telemetry([[:cache, :stage]])
    opts = cache_opts(root, telemetry_prefix: prefix, cache: [max_body_bytes: 3])

    sink = Cache.open_sink(cache_key(), resolved_output(), opts)

    assert Cache.write_chunk(sink, "abcd", opts) == nil

    assert_receive {:telemetry_event, _event, _measurements,
                    %{cache: :stage_skipped, reason: :too_large, output_format: :webp}}

    assert {:miss, %Key{}} = Cache.lookup_entry(cache_key(), opts)
    assert stored_files(root) == []
  end

  test "commit_sink errors fail open through cache write telemetry", %{root: root} do
    prefix = attach_telemetry([[:cache, :write, :stop]])
    opts = cache_opts(root, telemetry_prefix: prefix)

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), opts)
      |> Cache.write_chunk("abc", opts)

    {:ok, %{dir: dir}} = FileSystem.paths(cache_key(), Keyword.fetch!(opts, :cache))
    File.chmod!(dir, 0o500)

    capture_log(fn -> assert :ok = Cache.commit_sink(sink, opts) end)

    assert_receive {:telemetry_event, _event, _measurements,
                    %{result: :cache_error, cache: :write_error, output_format: :webp}}
  end

  test "commit_sink reports admission rejection on the cache write span", %{root: root} do
    prefix = attach_telemetry([[:cache, :write, :stop]])

    # A bounded cache smaller than the entry declines to keep it.
    opts =
      cache_opts(root,
        telemetry_prefix: prefix,
        cache: [max_size_bytes: 2, node_id: "cache-test"]
      )

    start_supervised!(FileSystem.child_spec(Keyword.fetch!(opts, :cache)))

    sink =
      cache_key()
      |> Cache.open_sink(resolved_output(), opts)
      |> Cache.write_chunk("abc", opts)

    # Rejection is a successful, non-error outcome: the request path fails open
    # (nothing stored) and Cache.commit_sink still returns :ok.
    assert :ok = Cache.commit_sink(sink, opts)

    assert_receive {:telemetry_event, _event, _measurements,
                    %{result: :ok, cache: :admission_rejected, output_format: :webp}}

    assert {:miss, %Key{}} = Cache.lookup_entry(cache_key(), opts)
  end

  defp cache_opts(root, extra \\ []) do
    {cache, extra} = Keyword.pop(extra, :cache, [])
    Cache.validate_config!([cache: [root: root] ++ cache] ++ extra)
  end

  # Regular files left in the cache root, outside its bookkeeping directories.
  defp stored_files(root) do
    root
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  # Attaches to `events` under a private telemetry prefix and returns it.
  defp attach_telemetry(events) do
    prefix = [:"cache_test_#{System.unique_integer([:positive])}"]
    handler_id = {__MODULE__, self(), make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        Enum.map(events, &(prefix ++ &1)),
        &__MODULE__.handle_telemetry_event/4,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    prefix
  end
end
