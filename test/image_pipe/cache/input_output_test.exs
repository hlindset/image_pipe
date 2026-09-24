defmodule ImagePipe.Cache.InputOutputTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Key
  alias ImagePipe.Source
  alias ImagePipe.Source.Record
  alias ImagePipe.Test.PlugFixture.CacheProbe

  setup do
    table = :ets.new(:source_records, [:set, :public])
    key = %Key{hash: Base.encode16(:crypto.strong_rand_bytes(32)), data: []}
    {:ok, source, _} = Source.from_input({:binary, "image"}, sources: %{})
    record = Record.new(source, :crypto.hash(:sha256, "image"), nil, 1000)
    %{key: key, record: record, pool: [store: table]}
  end

  test "successful source publication commits without aborting", ctx do
    opts = [cache: {CacheProbe, ctx.pool}]
    assert {:ok, snapshot} = publish(ctx, opts)
    assert Input.lookup(ctx.key, opts) == snapshot
    refute_received {:cache_abort, _}
  end

  test "failed source writes abort the updated sink state", ctx do
    assert {:error, :write_failed} =
             publish(ctx, cache: {CacheProbe, [write_error: :write_failed] ++ ctx.pool})

    assert_received {:cache_abort, [body]}
    assert is_binary(body)
    refute_received {:cache_put, _, _}
  end

  test "source snapshots respect the per-entry byte limit", ctx do
    opts = [cache: {CacheProbe, [max_body_bytes: 0] ++ ctx.pool}]
    assert {:error, :too_large} = publish(ctx, opts)
    assert Input.lookup(ctx.key, opts) == nil
    refute_received {:cache_put, _, _}
  end

  test "output-only ownership is shared across option order and policy differences", ctx do
    first = [cache: {CacheProbe, ctx.pool ++ [max_body_bytes: 10_000]}]
    second = [cache: {CacheProbe, [max_body_bytes: 20_000] ++ ctx.pool}]
    {:ok, lease} = Input.acquire(ctx.key, first)
    parent = self()
    supervisor = start_supervised!(Task.Supervisor)

    task =
      Task.Supervisor.async_nolink(supervisor, fn ->
        send(parent, :attempting_acquire)
        {:ok, next} = Input.acquire(ctx.key, second)
        send(parent, :acquired)
        Input.release_source(next)
      end)

    assert_receive :attempting_acquire
    refute_receive :acquired
    Input.release_source(lease)
    assert_receive :acquired
    Task.await(task)
  end

  defp publish(ctx, opts) do
    {:ok, lease} = Input.acquire(ctx.key, opts)

    try do
      Input.publish(ctx.key, lease, ctx.record, nil, 0, opts)
    after
      Input.release_source(lease)
    end
  end
end
