defmodule ImagePipe.Cache.SharedFileSystem.GenerationTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem.{Generation, Partition, Storage}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Source
  alias ImagePipe.Source.Record

  setup do
    root = Path.join(System.tmp_dir!(), "shared_generation_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!({CacheIO, max_resource_bytes: 1_000_000}) |> CacheIO.client()

    {:ok, {:ok, partition}} =
      CacheIO.run(pool, {Partition, :create, [Path.join(root, "shared")]}, 0, 1_000)

    source = Path.join(root, "source")
    File.write!(source, "encoded image")
    readers = Path.join(root, "readers")
    File.mkdir!(readers)
    plan = Partition.plan(partition, :outputs, String.duplicate("a", 64))
    %{pool: pool, root: root, source: source, readers: readers, partition: partition, plan: plan}
  end

  test "publishes an immutable pair and holds a reader independently of shared cleanup", ctx do
    metadata = %{content_type: "image/png", created_at: ~U[2026-09-25 00:00:00Z]}
    assert {:ok, location} = publish(ctx, metadata)
    assert location.path == ctx.plan.destination
    assert File.ls!(location.path) |> Enum.sort() == ["body", "meta"]
    assert {:ok, reader} = acquire(ctx, location)
    assert reader.metadata == metadata
    File.rm_rf!(ctx.partition.path)
    assert File.read!(reader.path) == "encoded image"
    assert :ok = Generation.release(ctx.pool, reader, 1_000)
    refute File.exists?(reader.path)
  end

  test "oversized bodies and metadata never publish", ctx do
    File.write!(ctx.source, String.duplicate("x", 33))
    assert {:error, :body_too_large} = publish(ctx, %{})
    refute File.exists?(ctx.plan.destination)
    File.write!(ctx.source, "small")
    ctx = %{ctx | plan: Partition.plan(ctx.partition, :outputs, ctx.plan.key)}
    assert {:error, :metadata_too_large} = publish(ctx, %{large: String.duplicate("x", 2_000)})
    refute File.exists?(ctx.plan.destination)
  end

  test "a retired incarnation cannot be recreated by a pending publication", ctx do
    {:ok, {:ok, _trash}} = CacheIO.run(ctx.pool, {Partition, :retire, [ctx.partition]}, 0, 1_000)
    assert {:error, :enoent} = publish(ctx, %{})
    refute File.exists?(ctx.partition.path)
  end

  test "corrupt or missing body is rejected before returning a reader", ctx do
    assert {:ok, location} = publish(ctx, %{})
    body = Path.join(location.path, "body")
    File.write!(body, "corrupted")
    assert {:error, :corrupt} = acquire(ctx, location)
    File.rm!(body)
    assert {:error, :enoent} = acquire(ctx, location)
  end

  test "metadata is bounded and rejects compressed terms before decoding", ctx do
    assert {:ok, location} = publish(ctx, %{})
    meta = Path.join(location.path, "meta")
    File.write!(meta, :erlang.term_to_binary(String.duplicate("x", 10_000), [:compressed]))
    assert {:error, :corrupt} = acquire(ctx, location)
    File.write!(meta, String.duplicate("x", 1_025))
    assert {:error, :metadata_too_large} = acquire(ctx, location)
  end

  test "a metadata file cannot substitute another generation", ctx do
    assert {:ok, first} = publish(ctx, %{})
    other = %{ctx | plan: Partition.plan(ctx.partition, :outputs, ctx.plan.key)}
    assert {:ok, second} = publish(other, %{})
    File.cp!(Path.join(first.path, "meta"), Path.join(second.path, "meta"))
    assert {:error, :corrupt} = acquire(ctx, second)
  end

  test "a successful publication can be reconciled after losing its acknowledgement", ctx do
    assert {:ok, location} = publish(ctx, %{})

    assert {:ok, {:ok, ^location}} =
             CacheIO.run(ctx.pool, {Storage, :commit, [ctx.plan, limits()]}, 1_000_000, 1_000)

    File.write!(Path.join(location.path, "body"), "corrupt")

    assert {:ok, {:error, :corrupt}} =
             CacheIO.run(ctx.pool, {Storage, :commit, [ctx.plan, limits()]}, 1_000_000, 1_000)
  end

  test "acquired bytes survive helper failure", ctx do
    assert {:ok, location} = publish(ctx, %{})
    assert {:ok, reader} = acquire(ctx, location)
    assert {:error, _reason} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)
    File.rm_rf!(ctx.partition.path)
    assert File.read!(reader.path) == "encoded image"
    assert :ok = Generation.release(ctx.pool, reader, 1_000)
    refute File.exists?(reader.path)
    refute File.exists?(Path.dirname(reader.path))
  end

  test "original identities include the input identity", ctx do
    first = Partition.original_key(ctx.plan.key, "opaque revision")
    second = Partition.original_key(String.duplicate("b", 64), "opaque revision")
    refute first == second
    assert first == Partition.original_key(ctx.plan.key, "opaque revision")
  end

  test "source evidence can be published and read without an original body", ctx do
    plan = Partition.plan(ctx.partition, :sources, ctx.plan.key)
    {:ok, source, _config} = Source.from_input({:binary, "image"}, sources: %{})
    record = Record.new(source, :crypto.hash(:sha256, "image"), nil, 1_000)
    assert {:ok, location} = Generation.publish(ctx.pool, plan, nil, record, limits(), 1_000)
    assert File.ls!(location.path) == ["meta"]

    assert {:ok, %{metadata: ^record, body: nil}} =
             Generation.metadata(ctx.pool, location, limits(), 1_000)

    assert {:ok, {:ok, ^location}} =
             CacheIO.run(ctx.pool, {Storage, :commit, [plan, limits()]}, 1_000_000, 1_000)
  end

  test "serialized source evidence is validated at the storage boundary", ctx do
    plan = Partition.plan(ctx.partition, :sources, ctx.plan.key)
    {:ok, source, _config} = Source.from_input({:binary, "image"}, sources: %{})
    record = Record.new(source, :crypto.hash(:sha256, "image"), nil, 1_000)
    assert {:ok, location} = Generation.publish(ctx.pool, plan, nil, record, limits(), 1_000)
    path = Path.join(location.path, "meta")
    envelope = path |> File.read!() |> :erlang.binary_to_term()

    File.write!(
      path,
      :erlang.term_to_binary(%{
        envelope
        | metadata: :erlang.term_to_binary(%{record | received_at: "bad"})
      })
    )

    assert {:error, :corrupt} = Generation.metadata(ctx.pool, location, limits(), 1_000)

    malformed = %{record | origin: %{__struct__: ImagePipe.Source.Origin}}

    File.write!(
      path,
      :erlang.term_to_binary(%{envelope | metadata: :erlang.term_to_binary(malformed)})
    )

    assert {:error, :corrupt} = Generation.metadata(ctx.pool, location, limits(), 1_000)

    compressed = :erlang.term_to_binary(String.duplicate("x", 10_000), [:compressed])
    File.write!(path, :erlang.term_to_binary(%{envelope | metadata: compressed}))
    assert {:error, :corrupt} = Generation.metadata(ctx.pool, location, limits(), 1_000)
  end

  test "record-only invalidation is distinct from a missing generation", ctx do
    plan = Partition.plan(ctx.partition, :sources, ctx.plan.key)
    assert {:ok, location} = Generation.publish(ctx.pool, plan, nil, nil, limits(), 1_000)

    assert {:ok, %{metadata: nil, body: nil}} =
             Generation.metadata(ctx.pool, location, limits(), 1_000)

    File.rm_rf!(location.path)
    assert {:error, :enoent} = Generation.metadata(ctx.pool, location, limits(), 1_000)
  end

  test "a cold independent helper can read another writer's source record", ctx do
    plan = Partition.plan(ctx.partition, :sources, ctx.plan.key)
    {:ok, source, _config} = Source.from_input({:binary, "image"}, sources: %{})
    record = Record.new(source, :crypto.hash(:sha256, "image"), nil, 1_000)
    assert {:ok, location} = Generation.publish(ctx.pool, plan, nil, record, limits(), 1_000)

    other =
      start_supervised!(Supervisor.child_spec(CacheIO, id: :independent_reader))
      |> CacheIO.client()

    assert {:ok, %{metadata: ^record}} = Generation.metadata(other, location, limits(), 1_000)
  end

  test "reader ownership survives executor shutdown", ctx do
    assert {:ok, location} = publish(ctx, %{})
    assert {:ok, reader} = acquire(ctx, location)
    stop_supervised!(CacheIO)
    assert File.read!(reader.path) == "encoded image"
    assert :ok = Generation.release(ctx.pool, reader, 1_000)
    refute File.exists?(Path.dirname(reader.path))
  end

  test "caller death cleans its reader after helper failure", ctx do
    assert {:ok, location} = publish(ctx, %{})
    parent = self()
    tasks = start_supervised!(Task.Supervisor)

    owner =
      Task.Supervisor.async_nolink(tasks, fn ->
        {:ok, reader} = acquire(ctx, location)
        send(parent, {:reader, reader})

        receive do
          :finish -> :ok
        end
      end)

    assert_receive {:reader, reader}, 1_000
    assert {:error, _reason} = CacheIO.run(ctx.pool, {:erlang, :halt, []}, 0, 1_000)
    assert File.read!(reader.path) == "encoded image"
    Task.shutdown(owner, :brutal_kill)
    _ = :sys.get_state(ImagePipe.Cache.Resources)
    refute File.exists?(Path.dirname(reader.path))
  end

  defp publish(ctx, metadata) do
    Generation.publish(ctx.pool, ctx.plan, ctx.source, metadata, limits(), 1_000)
  end

  defp acquire(ctx, location) do
    Generation.acquire(ctx.pool, location, ctx.readers, limits(), 1_000)
  end

  defp limits, do: %{body: 32, metadata: 1_024}
end
