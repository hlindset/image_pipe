defmodule ImagePipe.Cache.SharedFileSystem.DiskFaultTest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.SharedFileSystem

  alias ImagePipe.Cache.SharedFileSystem.{
    Generation,
    InventoryWorker,
    Partition,
    Retainer,
    Runtime,
    Usage
  }

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  @moduletag :shared_disk_fault
  @limits %{body: 4 * 1024 * 1024, metadata: 4_096}

  setup_all do
    mount = System.fetch_env!("IMAGE_PIPE_FAULT_VOLUME")
    {output, 0} = System.cmd("df", ["-Pk", mount])

    [_device, blocks | _] =
      output |> String.split("\n", trim: true) |> List.last() |> String.split()

    assert String.to_integer(blocks) <= 32 * 1024, "requires a disposable filesystem <= 32 MiB"
    refute File.stat!(mount).major_device == File.stat!(System.tmp_dir!()).major_device
    Mix.Task.run("image_pipe.shared_cache.build")
    %{mount: mount}
  end

  setup ctx do
    id = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    root = Path.join(ctx.mount, id)
    local = Path.join(System.tmp_dir!(), "shared-disk-fault-" <> id)
    File.mkdir!(root)
    File.mkdir!(local)

    on_exit(fn ->
      File.rm_rf!(root)
      File.rm_rf!(local)
    end)

    pool = start_supervised!({CacheIO, max_resource_bytes: 32 * 1024 * 1024}) |> CacheIO.client()
    :erlang.trace(pool.pid, true, [:receive])
    {:ok, writer} = Partition.create(Path.join(local, "writer"))
    {:ok, adopter} = Partition.create(Path.join(root, "adopter"))
    source = Path.join(local, "source")
    File.write!(source, String.duplicate("x", 2 * 1024 * 1024))
    key = String.duplicate("a", 64)

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      output_format: :png,
      representation: {:image, :png}
    }

    assert {:ok, original} =
             Generation.publish(
               pool,
               Partition.plan(writer, :outputs, key),
               source,
               metadata,
               @limits,
               5_000
             )

    %{
      root: root,
      local: local,
      pool: pool,
      writer: writer,
      adopter: adopter,
      original: original,
      source: source,
      key: key,
      metadata: metadata
    }
  end

  test "cross-device adoption copies complete bytes and preserves metadata", ctx do
    assert {:error, :exdev} =
             File.ln(Path.join(ctx.original.path, "body"), Path.join(ctx.root, "probe"))

    plan = Partition.plan(ctx.adopter, :outputs, ctx.key)
    assert {:ok, adopted} = Generation.adopt(ctx.pool, plan, ctx.original, @limits, 5_000)
    File.rm_rf!(ctx.writer.path)
    assert {:ok, reader} = Generation.acquire(ctx.pool, adopted, ctx.local, @limits, 5_000)
    assert File.read!(reader.path) == File.read!(ctx.source)
    assert reader.metadata == ctx.metadata
    assert :ok = Generation.release(ctx.pool, reader, 5_000)
  end

  test "out-of-space copying never publishes a generation and releases staging", ctx do
    reserve = Path.join(ctx.root, "reserve")
    File.write!(reserve, String.duplicate("r", 128 * 1024))
    fill(ctx.root)
    File.rm!(reserve)
    plan = Partition.plan(ctx.adopter, :outputs, ctx.key)
    assert {:error, :enospc} = Generation.adopt(ctx.pool, plan, ctx.original, @limits, 5_000)
    refute File.exists?(plan.destination)
    settle(ctx.pool.pid)
    refute File.exists?(plan.stage)
    assert :sys.get_state(ctx.pool.pid).leases.bytes == 0
    assert File.read!(Path.join(ctx.original.path, "body")) == File.read!(ctx.source)
  end

  test "same-filesystem unsupported hard links fall back to copying", ctx do
    {:ok, writer} = Partition.create(Path.join(ctx.root, "same-device-writer"))

    assert {:ok, original} =
             Generation.publish(
               ctx.pool,
               Partition.plan(writer, :outputs, ctx.key),
               ctx.source,
               ctx.metadata,
               @limits,
               5_000
             )

    assert {:error, reason} =
             File.ln(Path.join(original.path, "body"), Path.join(ctx.root, "probe"))

    assert reason in [:enotsup, :eperm]

    assert {:ok, adopted} =
             Generation.adopt(
               ctx.pool,
               Partition.plan(ctx.adopter, :outputs, ctx.key),
               original,
               @limits,
               5_000
             )

    File.rm_rf!(writer.path)
    assert {:ok, reader} = Generation.acquire(ctx.pool, adopted, ctx.local, @limits, 5_000)
    assert File.read!(reader.path) == File.read!(ctx.source)
    assert reader.metadata == ctx.metadata
    assert :ok = Generation.release(ctx.pool, reader, 5_000)
  end

  test "full shared storage still delivers generated pixels", ctx do
    start_supervised!(
      {SharedFileSystem,
       name: __MODULE__.Runtime,
       root: Path.join(ctx.root, "runtime"),
       local_root: Path.join(ctx.local, "runtime")}
    )

    assert {:ok, _context} = Runtime.context(__MODULE__.Runtime)
    encoded = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".png")

    origin = fn conn ->
      conn
      |> put_resp_header("cache-control", "public, max-age=60")
      |> put_resp_content_type("image/png")
      |> send_resp(200, encoded)
    end

    opts =
      ImagePipe.Plug.init(
        cache: {SharedFileSystem, runtime: __MODULE__.Runtime},
        sources: [
          url:
            {ImagePipe.Source.HTTP,
             allowed_hosts: ["origin.test"],
             address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
             req_options: [plug: origin]}
        ]
      )

    fill(ctx.root)

    response =
      conn(:get, "/w=12/format=png/src/https://origin.test/image.png")
      |> ImagePipe.Plug.call(opts)

    assert response.status == 200
    image = Image.from_binary!(response.resp_body)
    assert {Image.width(image), Image.height(image)} == {12, 8}
    assert Image.get_pixel!(image, 0, 0) == [255, 0, 0]
    assert Path.wildcard(Path.join(ctx.root, "runtime/partitions/*/outputs/*/*/*/body")) == []
  end

  test "full storage still permits pressure eviction using prior usage", ctx do
    supervisor =
      start_supervised!(
        {SharedFileSystem,
         name: __MODULE__.Pressure,
         root: Path.join(ctx.root, "pressure"),
         local_root: Path.join(ctx.local, "pressure"),
         root_max_bytes: 1_024,
         max_retained_bytes: 8 * 1024 * 1024}
      )

    {:ok, context} = Runtime.context(__MODULE__.Pressure)
    :erlang.trace(context.retainer.pid, true, [:receive])

    assert {:ok, location} =
             Retainer.publish(
               context.retainer,
               :outputs,
               ctx.key,
               ctx.source,
               ctx.metadata,
               2 * 1024 * 1024,
               5_000
             )

    settle_retainer(context.retainer.pid)

    {InventoryWorker, worker, _, _} =
      List.keyfind(Supervisor.which_children(supervisor), InventoryWorker, 0)

    opts = :sys.get_state(worker).opts
    stats = Retainer.stats(context.retainer, 1_000)
    assert :ok = Usage.publish(context.pool, context.partition, stats, opts[:clock].(), 5_000)
    fill(ctx.root)

    assert {:error, %{inventory: {:error, _}, pressure: {:ok, %{usage_publication: {:error, _}}}}} =
             InventoryWorker.run(__MODULE__.Pressure, opts, :publish)

    settle_retainer(context.retainer.pid)
    assert %{bytes: 0, cleanup_bytes: 0, failure: nil} = Retainer.stats(context.retainer, 1_000)
    refute File.exists?(location.path)
  end

  defp settle_retainer(pid) do
    case :sys.get_state(pid) do
      %{job: nil} ->
        :ok

      %{failure: nil, job: %{ref: ref}} ->
        assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 5_000
        settle_retainer(pid)

      %{failure: failure} ->
        flunk("retention failed: #{inspect(failure)}")
    end
  end

  @tag capture_log: true
  test "helper loss during copy fallback keeps incomplete bytes unpublished and charged", ctx do
    source = Path.join(ctx.original.path, "body")
    File.rm!(source)
    {_, 0} = System.cmd("mkfifo", [source])
    {:ok, fifo} = :file.open(String.to_charlist(source), [:read, :write, :binary, :raw])
    tasks = start_supervised!(Task.Supervisor)
    plan = Partition.plan(ctx.adopter, :outputs, ctx.key)

    try do
      task =
        Task.Supervisor.async_nolink(tasks, fn ->
          Generation.adopt(ctx.pool, plan, ctx.original, @limits, 5_000)
        end)

      assert :ok = :file.write(fifo, String.duplicate("x", 256 * 1024))
      assert File.exists?(Path.join(plan.stage, "body"))
      :peer.stop(:sys.get_state(ctx.pool.pid).peer)
      assert {:error, :unavailable} = Task.await(task, 5_000)
      refute File.exists?(plan.destination)
      assert :sys.get_state(ctx.pool.pid).leases.bytes > 0
    after
      :file.close(fifo)
    end
  end

  defp fill(root) do
    {:ok, file} =
      :file.open(String.to_charlist(Path.join(root, "filler")), [
        :write,
        :binary,
        :raw,
        :exclusive
      ])

    try do
      result =
        Enum.reduce_while(1..8_192, :not_full, fn _, _ ->
          case :file.write(file, <<0::size(4096 * 8)>>) do
            :ok -> {:cont, :not_full}
            {:error, :enospc} -> {:halt, :full}
          end
        end)

      assert result == :full
    after
      :file.close(file)
    end
  end

  defp settle(pid) do
    case Map.keys(:sys.get_state(pid).jobs) do
      [] ->
        :ok

      [ref | _] ->
        assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 5_000
        settle(pid)
    end
  end
end
