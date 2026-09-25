defmodule ImagePipe.Cache.SharedFileSystem.PressureTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.SharedFileSystem
  alias ImagePipe.Cache.SharedFileSystem.{InventoryWorker, Partition, Pressure, Retainer, Runtime}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_pressure_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    opts = opts(root)
    supervisor = start_supervised!({SharedFileSystem, opts})

    {InventoryWorker, worker, _, _} =
      List.keyfind(Supervisor.which_children(supervisor), InventoryWorker, 0)

    :erlang.trace(worker, true, [:receive])
    settle_worker(worker)
    {:ok, context} = Runtime.context(__MODULE__.Cache)
    :erlang.trace(context.retainer.pid, true, [:receive])
    %{root: root, context: context, opts: opts, worker: worker}
  end

  test "periodic publication applies volume pressure and can restore capacity", ctx do
    path = Path.join(ctx.root, "body")
    File.write!(path, String.duplicate("x", 400))
    key = Base.encode16(:crypto.hash(:sha256, "key"), case: :lower)

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: DateTime.utc_now(),
      representation: {:image, :png},
      output_format: :png
    }

    assert {:ok, location} =
             Retainer.publish(ctx.context.retainer, :outputs, key, path, metadata, 400, 1_000)

    send(ctx.worker, :tick)
    settle_worker(ctx.worker)
    settle_retainer(ctx.context.retainer.pid)

    assert %{capacity: capacity, bytes: 0, cleanup_bytes: 0} =
             Retainer.stats(ctx.context.retainer, 1_000)

    assert capacity <= 400
    refute File.exists?(location.path)
    assert File.exists?(Path.join(ctx.context.partition.path, "usage"))
    assert {:ok, %{target: 10_000}} = Pressure.run(ctx.context, ctx.opts, 1_000)
    assert %{capacity: 10_000} = Retainer.stats(ctx.context.retainer, 1_000)
  end

  test "incomplete reports cannot restore a previously reduced capacity", ctx do
    assert {:ok, :complete} = Retainer.resize(ctx.context.retainer, 100, 1_000)

    {:ok, {:ok, _unreported}} =
      CacheIO.run(ctx.context.pool, {Partition, :create, [ctx.context.partition.root]}, 0, 1_000)

    assert {:ok, %{unavailable: 1, target: 100}} = Pressure.run(ctx.context, ctx.opts, 1_000)
    assert %{capacity: 100} = Retainer.stats(ctx.context.retainer, 1_000)
  end

  test "invalid watermarks fail before creating storage", ctx do
    path = Path.join(ctx.root, "invalid")

    for watermark <- [0.0, 1.0, -0.1] do
      assert_raise ArgumentError, fn ->
        Runtime.start_link(
          Keyword.merge(ctx.opts,
            name: __MODULE__.Invalid,
            root: path,
            root_low_watermark: watermark
          )
        )
      end
    end

    refute File.exists?(path)
  end

  defp settle_worker(pid) do
    case :sys.get_state(pid) do
      %{job: nil, phase: :publish} ->
        :ok

      %{job: ref} ->
        assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 2_000
        settle_worker(pid)
    end
  end

  defp settle_retainer(pid) do
    case :sys.get_state(pid) do
      %{job: nil} ->
        :ok

      %{job: %{ref: ref}} ->
        assert_receive {:trace, ^pid, :receive, {^ref, _result}}, 2_000
        settle_retainer(pid)
    end
  end

  defp opts(root),
    do: [
      name: __MODULE__.Cache,
      root: Path.join(root, "shared"),
      local_root: Path.join(root, "local"),
      root_max_bytes: 500,
      root_low_watermark: 0.8,
      usage_max_partitions: 16,
      max_retained_bytes: 10_000,
      inventory_interval: 60_000,
      clock_skew: 5,
      clock: fn -> 100 end
    ]
end
