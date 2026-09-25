defmodule ImagePipe.Cache.SharedFileSystem.SinkTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.{Entry, Key, SharedFileSystem}
  alias ImagePipe.Cache.SharedFileSystem.Runtime

  setup do
    root = Path.join(System.tmp_dir!(), "shared_sink_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    start_supervised!(
      {SharedFileSystem,
       name: __MODULE__.Cache,
       root: Path.join(root, "shared"),
       local_root: Path.join(root, "local")}
    )

    {:ok, opts} = SharedFileSystem.validate_options(runtime: __MODULE__.Cache, timeout: 1_000)
    key = %Key{hash: Base.encode16(:crypto.hash(:sha256, "body"), case: :lower), data: []}

    metadata = %Entry.Metadata{
      content_type: "text/plain",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: nil,
      representation: {:complete_body, "text/plain"}
    }

    %{opts: opts, key: key, metadata: metadata, root: root}
  end

  test "time spent producing the next chunk does not consume cache I/O allowance", ctx do
    assert {:ok, sink} = SharedFileSystem.open_sink(ctx.key, ctx.metadata, ctx.opts)
    assert {:ok, sink} = SharedFileSystem.write_chunk(sink, "first", ctx.opts)
    # Model encoder backpressure longer than the entire cache wait allowance.
    token = make_ref()
    Process.send_after(self(), {:next_chunk, token}, ctx.opts[:timeout] + 50)
    assert_receive {:next_chunk, ^token}, 2_000
    assert {:ok, sink} = SharedFileSystem.write_chunk(sink, "second", ctx.opts)
    assert :ok = SharedFileSystem.commit_sink(sink, ctx.opts)
    assert {:hit, %{body: "firstsecond"}} = SharedFileSystem.get(ctx.key, ctx.opts)
  end

  test "a stalled cache write consumes its allowance and can be abandoned safely", ctx do
    opts = Keyword.put(ctx.opts, :timeout, 100)
    assert {:ok, sink} = SharedFileSystem.open_sink(ctx.key, ctx.metadata, opts)
    {:ok, context} = Runtime.context(__MODULE__.Cache)
    :sys.suspend(context.pool.pid)

    try do
      assert {:error, :timeout, failed} = SharedFileSystem.write_chunk(sink, "body", opts)
      assert :ok = SharedFileSystem.abort_sink(failed, opts)
    after
      :sys.resume(context.pool.pid)
    end

    assert Path.wildcard(Path.join(ctx.root, "shared/partitions/*/outputs/*/*/*/meta")) == []
  end
end
