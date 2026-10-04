defmodule ImagePipe.API.FileSourceCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Test.PlugFixture.CacheProbe

  @path "/w=12/format=png/src/media/beach.jpg"

  setup %{test: test} do
    root =
      Path.join(System.tmp_dir!(), "image-pipe-file-cache-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    File.cp!("priv/static/images/beach.jpg", Path.join(root, "beach.jpg"))

    prefix = [:file_source_cache, test]
    handler = {__MODULE__, make_ref()}
    event = prefix ++ [:source, :fetch, :stop]
    :ok = :telemetry.attach(handler, event, &__MODULE__.forward/4, self())
    on_exit(fn -> :telemetry.detach(handler) end)

    %{root: root, prefix: prefix}
  end

  test "a file that can change gets a digest ETag and a cached output", ctx do
    opts = mount(ctx)
    first = get(@path, opts)

    assert first.status == 200
    assert [etag] = get_resp_header(first, "etag")
    assert ["public, max-age=0" <> _] = get_resp_header(first, "cache-control")
    assert_received {:fetch, :ok}
    assert_received {:cache_put, _key, _body}

    # An unchanged stat is enough: the file isn't read again.
    second = get(@path, opts)
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "etag") == [etag]
    assert_received {:fetch, :not_modified}

    conditional = get(@path, opts, [{"if-none-match", etag}])
    assert conditional.status == 304
  end

  test "a changed file gets a new ETag", ctx do
    opts = mount(ctx)
    [etag] = get_resp_header(get(@path, opts), "etag")

    Image.new!(30, 20, color: :red)
    |> Image.write!(Path.join(ctx.root, "beach.jpg"), suffix: ".jpg")

    changed = get(@path, opts)
    assert changed.status == 200
    refute get_resp_header(changed, "etag") == [etag]
    assert {Image.width(image(changed)), Image.height(image(changed))} == {12, 8}
  end

  test "a file written in the second it was hashed is hashed again", ctx do
    file = Path.join(ctx.root, "beach.jpg")
    opts = mount(ctx, clock: fn -> File.stat!(file, time: :posix).mtime end)
    _first = get(@path, opts)
    flush_fetches()

    _second = get(@path, opts)
    assert_received {:fetch, :ok}
  end

  test "verify: :hash reads the file on every request", ctx do
    opts = mount(ctx, file_options: [verify: :hash])
    _first = get(@path, opts)
    flush_fetches()

    _second = get(@path, opts)
    assert_received {:fetch, :ok}
  end

  test "a fallback lifetime skips the stat while fresh", ctx do
    opts = mount(ctx, file_options: [cache_policy: [freshness: {:fallback, 60}]])
    first = get(@path, opts)
    assert ["public, max-age=60" <> _] = get_resp_header(first, "cache-control")
    flush_fetches()

    _second = get(@path, opts)
    refute_received {:fetch, _result}
  end

  test "a host ETag on a file source is left alone", ctx do
    response =
      :get
      |> conn(@path)
      |> put_resp_header("etag", ~s("host"))
      |> ImagePipe.Plug.call(mount(ctx))

    assert response.status == 200
    assert get_resp_header(response, "etag") == [~s("host")]
  end

  test "by default the original is read in place and never copied", ctx do
    input_root = Path.join(ctx.root, "input-pool")
    opts = mount(ctx, input_cache: {ImagePipe.Cache.FileSystem, root: input_root})

    assert get(@path, opts).status == 200
    assert get("/w=8/format=png/src/media/beach.jpg", opts).status == 200
    assert pooled(input_root) == []
  end

  test "copy: :keep keeps the original in the input pool", ctx do
    input_root = Path.join(ctx.root, "input-pool")

    opts =
      mount(ctx,
        file_options: [copy: :keep],
        input_cache: {ImagePipe.Cache.FileSystem, root: input_root}
      )

    assert get(@path, opts).status == 200
    assert [_original | _] = pooled(input_root)
  end

  test "a write-once file's ETag depends on root_id and path, not copy or root", ctx do
    moved = Path.join(ctx.root, "moved")
    File.mkdir_p!(moved)
    File.cp!("priv/static/images/beach.jpg", Path.join(moved, "beach.jpg"))
    input_cache = {ImagePipe.Cache.FileSystem, root: Path.join(ctx.root, "input-pool")}

    etag = fn file_options ->
      opts =
        mount(ctx,
          file_options: [stable: :immutable] ++ file_options,
          input_cache: input_cache
        )

      [etag] = get_resp_header(get(@path, opts), "etag")
      etag
    end

    read_in_place = etag.([])

    assert etag.(copy: :keep) == read_in_place
    assert etag.(copy: :keep, root: moved) == read_in_place
    assert etag.(root: moved) == read_in_place
  end

  test "a write-once file with kept copies is cached by root_id, not root", ctx do
    moved = Path.join(ctx.root, "moved")
    File.mkdir_p!(moved)
    File.cp!("priv/static/images/beach.jpg", Path.join(moved, "beach.jpg"))

    caches = [
      cache: {CacheProbe, store: :ets.new(:file_source_cache, [:set, :public])},
      input_cache: {ImagePipe.Cache.FileSystem, root: Path.join(ctx.root, "input-pool")}
    ]

    first = get(@path, mount(ctx, [file_options: [stable: :immutable, copy: :keep]] ++ caches))
    assert first.status == 200
    flush_fetches()

    moved_opts =
      mount(ctx, [file_options: [stable: :immutable, copy: :keep, root: moved]] ++ caches)

    again = get(@path, moved_opts)
    assert again.resp_body == first.resp_body
    refute_received {:fetch, _result}
  end

  test "two sources over one root_id share cached images and ETags", ctx do
    file_source = fn prefix ->
      [
        adapter: ImagePipe.Source.File,
        match: [prefix: prefix],
        options: [root: ctx.root, root_id: "media", stable: :immutable]
      ]
    end

    opts = mount(ctx, sources: [media: file_source.("media"), photos: file_source.("photos")])

    first = get(@path, opts)
    assert_received {:cache_put, _key, _body}
    flush_fetches()

    second = get("/w=12/format=png/src/photos/beach.jpg", opts)
    assert second.resp_body == first.resp_body
    assert get_resp_header(second, "etag") == get_resp_header(first, "etag")
    refute_received {:cache_put, _key, _body}
    refute_received {:fetch, _result}
  end

  test "one root_id for two directories fails configuration", ctx do
    other = Path.join(ctx.root, "other")

    assert_raise ArgumentError, ~r/root_id/, fn ->
      mount(ctx,
        sources: [
          media: [
            adapter: ImagePipe.Source.File,
            match: [prefix: "media"],
            options: [root: ctx.root, root_id: "media"]
          ],
          other: [
            adapter: ImagePipe.Source.File,
            match: [prefix: "other"],
            options: [root: other, root_id: "media"]
          ]
        ]
      )
    end
  end

  test "a watermark from a file mount keeps the response cacheable", ctx do
    File.cp!("priv/static/images/beach.jpg", Path.join(ctx.root, "mark.jpg"))
    opts = mount(ctx, watermarks: %{mark: [source: "media/mark.jpg"]})

    response = get("/wm=mark/w=12/format=png/src/media/beach.jpg", opts)
    assert response.status == 200
    assert [_etag] = get_resp_header(response, "etag")
    refute get_resp_header(response, "cache-control") == ["no-store"]
  end

  def forward(_event, _measurements, metadata, pid), do: send(pid, {:fetch, metadata.result})

  defp flush_fetches do
    receive do
      {:fetch, _} -> flush_fetches()
    after
      0 -> :ok
    end
  end

  defp get(path, opts, headers \\ []) do
    conn = conn(:get, path)

    conn =
      Enum.reduce(headers, conn, fn {name, value}, acc -> put_req_header(acc, name, value) end)

    ImagePipe.Plug.call(conn, opts)
  end

  defp image(response), do: Image.from_binary!(response.resp_body)

  defp pooled(root), do: Path.wildcard(Path.join(root, "**/*.body"))

  # The clock runs ahead by default so a file copied during setup counts as
  # written before it was hashed.
  defp mount(ctx, overrides \\ []) do
    {file_options, overrides} = Keyword.pop(overrides, :file_options, [])

    [
      sources: [
        media: [
          adapter: ImagePipe.Source.File,
          match: [prefix: "media"],
          options: Keyword.merge([root: ctx.root, root_id: "media"], file_options)
        ]
      ],
      cache: {CacheProbe, store: :ets.new(:file_source_cache, [:set, :public])},
      http_cache: :auto,
      telemetry_prefix: ctx.prefix,
      clock: fn -> System.os_time(:second) + 10 end
    ]
    |> Keyword.merge(overrides)
    |> ImagePipe.Plug.init()
  end
end
