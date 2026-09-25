defmodule ImagePipe.Cache.SharedFileSystem.LookupTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.SharedFileSystem.{Generation, Locations, Lookup, Partition, Sources}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Source
  alias ImagePipe.Source.Record

  setup_all do
    Mix.Task.run("image_pipe.shared_cache.build")
    :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "shared_lookup_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    tasks = start_supervised!(Task.Supervisor)

    locations =
      start_supervised!({Locations, pool: pool, root: root, tasks: tasks}) |> Locations.client()

    sources =
      start_supervised!({Sources.Supervisor, clock: fn -> 100 end}) |> Sources.client()

    {:ok, {:ok, partition}} = CacheIO.run(pool, {Partition, :create, [root]}, 0, 1_000)
    readers = Path.join(root, "readers")
    File.mkdir!(readers)
    body = Path.join(root, "body")
    File.write!(body, "encoded image")

    context = %{
      pool: pool,
      locations: locations,
      sources: sources,
      readers: readers,
      limits: %{body: 128, metadata: 4_096},
      max_attempts: 8
    }

    %{context: context, partition: partition, body: body, key: String.duplicate("a", 64)}
  end

  test "missing hinted generation falls back to disk and confirms a stable reader", ctx do
    first = publish(ctx, :outputs, ctx.key, output_metadata())
    second = publish(ctx, :outputs, ctx.key, output_metadata())
    :ok = Locations.remember(ctx.context.locations, first, 1_000)
    File.rm_rf!(first.path)
    assert {:hit, reader} = Lookup.output(ctx.context, ctx.key, 1_000)
    assert File.read!(reader.path) == "encoded image"
    assert {:ok, [^second]} = Locations.hints(ctx.context.locations, :outputs, ctx.key, 1_000)
    File.rm_rf!(ctx.partition.path)
    assert File.read!(reader.path) == "encoded image"
    assert :ok = Generation.release(ctx.context.pool, reader, 1_000)
  end

  test "corrupt typed metadata is skipped before a candidate can become a hit", ctx do
    good = publish(ctx, :outputs, ctx.key, output_metadata())
    bad = publish(ctx, :outputs, ctx.key, output_metadata())
    corrupt_metadata(bad, %{output_metadata() | headers: [{"cache-control", "bad\r\nheader"}]})
    :ok = Locations.remember(ctx.context.locations, bad, 1_000)
    assert {:hit, reader} = Lookup.output(ctx.context, ctx.key, 1_000)
    assert reader.metadata == output_metadata()
    assert {:ok, [^good]} = Locations.hints(ctx.context.locations, :outputs, ctx.key, 1_000)
    Generation.release(ctx.context.pool, reader, 1_000)
  end

  test "all unusable candidates yield a miss without retrying a generation", ctx do
    bad = publish(ctx, :outputs, ctx.key, output_metadata())
    File.write!(Path.join(bad.path, "body"), "corrupt")
    assert :miss = Lookup.output(%{ctx.context | max_attempts: 1}, ctx.key, 1_000)
    assert {:ok, []} = Locations.hints(ctx.context.locations, :outputs, ctx.key, 1_000)
  end

  test "candidate exhaustion differs from an ordinary miss", ctx do
    first = publish(ctx, :outputs, ctx.key, output_metadata())
    _second = publish(ctx, :outputs, ctx.key, output_metadata())
    :ok = Locations.remember(ctx.context.locations, first, 1_000)
    File.rm!(Path.join(first.path, "body"))

    assert {:error, :search_limit} =
             Lookup.output(%{ctx.context | max_attempts: 1}, ctx.key, 1_000)
  end

  test "original lookup checks stored byte identity and keeps evidence unchanged", ctx do
    expected = record("expected")
    other = record("other")
    key = Partition.original_key(ctx.key, expected.byte_identity)
    good = publish(ctx, :originals, key, %{source_record: expected, cost_us: 0})
    bad = publish(ctx, :originals, key, %{source_record: expected, cost_us: 0})
    corrupt_metadata(bad, %{source_record: other, cost_us: 0})
    :ok = Locations.remember(ctx.context.locations, bad, 1_000)
    assert {:hit, reader} = Lookup.original(ctx.context, ctx.key, expected, 1_000)
    assert reader.metadata.source_record == expected
    assert {:ok, [^good]} = Locations.hints(ctx.context.locations, :originals, key, 1_000)
    Generation.release(ctx.context.pool, reader, 1_000)
    assert :miss = Lookup.original(ctx.context, String.duplicate("b", 64), expected, 1_000)
  end

  test "source discovery installs evidence only under a live local lease", ctx do
    record = record("source")
    _location = publish(ctx, :sources, ctx.key, record)
    {:ok, lease, _} = Sources.acquire(ctx.context.sources, ctx.key, 1_000)
    assert {:hit, snapshot} = Lookup.source(ctx.context, ctx.key, lease, 1_000)
    assert snapshot.record == record
    assert snapshot.age_margin == 5
    assert {:hit, ^snapshot} = Sources.lookup(ctx.context.sources, ctx.key, 1_000)
    Sources.release(ctx.context.sources, lease)
    assert {:error, :ownership_lost} = Lookup.source(ctx.context, ctx.key, lease, 1_000)
  end

  test "an independent node invalidation marker does not suppress usable source evidence", ctx do
    record = record("source")
    _good = publish(ctx, :sources, ctx.key, record)
    marker = publish(ctx, :sources, ctx.key, nil)
    :ok = Locations.remember(ctx.context.locations, marker, 1_000)
    {:ok, lease, _} = Sources.acquire(ctx.context.sources, ctx.key, 1_000)
    assert {:hit, %{record: ^record}} = Lookup.source(ctx.context, ctx.key, lease, 1_000)
    Sources.release(ctx.context.sources, lease)
  end

  test "an expired request does no discovery or hint mutation", ctx do
    _location = publish(ctx, :outputs, ctx.key, output_metadata())
    assert {:error, :timeout} = Lookup.output(ctx.context, ctx.key, 0)
    assert %{keys: 0, jobs: 0} = Locations.stats(ctx.context.locations, 1_000)
  end

  defp publish(ctx, kind, key, metadata) do
    plan = Partition.plan(ctx.partition, kind, key)
    body = if kind == :sources, do: nil, else: ctx.body

    {:ok, location} =
      Generation.publish(ctx.context.pool, plan, body, metadata, ctx.context.limits, 1_000)

    location
  end

  defp output_metadata do
    %Entry.Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      output_format: :png,
      representation: {:image, :png}
    }
  end

  defp record(body) do
    {:ok, source, _config} = Source.from_input({:binary, body}, sources: %{})
    Record.new(source, :crypto.hash(:sha256, body), nil, 90)
  end

  defp corrupt_metadata(location, metadata) do
    path = Path.join(location.path, "meta")
    envelope = path |> File.read!() |> :erlang.binary_to_term()

    File.write!(
      path,
      :erlang.term_to_binary(%{envelope | metadata: :erlang.term_to_binary(metadata)})
    )
  end
end
