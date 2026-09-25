defmodule ImagePipe.Cache.SharedFileSystem.UsageTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.{Partition, Usage}

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_usage_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    {:ok, {:ok, first}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    {:ok, {:ok, second}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    %{root: root, pool: pool, first: first, second: second}
  end

  test "usage reports include pending and failed cleanup without double counting a report", ctx do
    assert :ok = Usage.publish(ctx.pool, ctx.first, stats(100, 20, 30), 100, 1_000)
    assert :ok = Usage.publish(ctx.pool, ctx.second, stats(200, 0, 0), 100, 1_000)
    assert {:ok, %{bytes: 350, reported: 2, unavailable: 0, scan: :complete}} = snapshot(ctx, 100)
    assert :ok = Usage.publish(ctx.pool, ctx.first, stats(10, 0, 0), 101, 1_000)
    assert {:ok, %{bytes: 210, reported: 2}} = snapshot(ctx, 101)
  end

  test "missing stale corrupt and foreign-incarnation reports are explicit gaps", ctx do
    assert :ok = Usage.publish(ctx.pool, ctx.first, stats(100, 0, 0), 100, 1_000)
    assert {:ok, %{bytes: 100, reported: 1, unavailable: 1}} = snapshot(ctx, 100)
    File.cp!(Path.join(ctx.first.path, "usage"), Path.join(ctx.second.path, "usage"))
    assert {:ok, %{bytes: 100, reported: 1, unavailable: 1}} = snapshot(ctx, 100)
    assert {:ok, %{bytes: 0, reported: 0, unavailable: 2}} = snapshot(ctx, 200)
    File.write!(Path.join(ctx.first.path, "usage"), String.duplicate("x", 4_097))
    assert {:ok, %{bytes: 0, reported: 0, unavailable: 2}} = snapshot(ctx, 100)
  end

  test "retirement prevents report resurrection and listing limits remain visible", ctx do
    assert {:ok, %{partitions: 1, scan: :limited}} =
             Usage.snapshot(ctx.pool, ctx.root, 100, %{limits() | partitions: 1}, 1_000)

    {:ok, {:ok, _trash}} = CacheIO.run(ctx.pool, {Partition, :retire, [ctx.first]}, 0, 1_000)
    assert {:error, :enoent} = Usage.publish(ctx.pool, ctx.first, stats(100, 0, 0), 100, 1_000)
    refute File.exists?(ctx.first.path)
  end

  test "future compressed trailing and negative usage cannot affect the estimate", ctx do
    assert :ok = Usage.publish(ctx.pool, ctx.first, stats(100, 0, 0), 100, 1_000)
    path = Path.join(ctx.first.path, "usage")
    valid = File.read!(path)
    envelope = :erlang.binary_to_term(valid)

    for payload <- [
          valid <> "trailing",
          :erlang.term_to_binary(put_elem(envelope, 4, -1)),
          :erlang.term_to_binary(put_elem(envelope, 3, 200)),
          :erlang.term_to_binary(put_elem(envelope, 4, String.duplicate("x", 20_000)), [
            :compressed
          ])
        ] do
      File.write!(path, payload)
      assert {:ok, %{bytes: 0, reported: 0, unavailable: 2}} = snapshot(ctx, 100)
    end
  end

  test "a stalled report scan returns within its deadline", ctx do
    :sys.suspend(ctx.pool.pid)

    try do
      assert {:error, :timeout} = Usage.snapshot(ctx.pool, ctx.root, 100, limits(), 50)
    after
      :sys.resume(ctx.pool.pid)
    end

    assert {:ok, %{reported: 0, unavailable: 2}} = snapshot(ctx, 100)
  end

  test "soft pressure is proportional, retains hysteresis and restores local capacity" do
    assert Usage.target(400, 500, 2_000, 1_000, 1_000, 0.8) == 160
    assert Usage.target(0, 500, 2_000, 1_000, 1_000, 0.8) == 0
    assert Usage.target(100, 160, 900, 1_000, 1_000, 0.8) == 160
    assert Usage.target(100, 160, 799, 1_000, 1_000, 0.8) == 1_000
  end

  defp stats(bytes, pending, cleanup),
    do: %{bytes: bytes, pending_bytes: pending, cleanup_bytes: cleanup}

  defp limits, do: %{partitions: 8, max_age: 60, clock_skew: 5}
  defp snapshot(ctx, now), do: Usage.snapshot(ctx.pool, ctx.root, now, limits(), 1_000)
end
