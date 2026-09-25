defmodule ImagePipe.Cache.SharedFileSystem.IndexTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.SharedFileSystem.{Index, Partition}

  test "ranked warmup retains its highest-ranked prefix without evicting earlier imports" do
    locations = Enum.map(["a", "b", "c"], &location/1)
    assert {index, 2, :full} = Index.seed(new(max_keys: 4, warm_fraction: 0.5), locations)
    [a, b, c] = locations
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.lookup(index, b.kind, b.key) == [b]
    assert Index.lookup(index, c.kind, c.key) == []
  end

  test "only successful reuse updates recency" do
    a = location("a")
    b = location("b")
    c = location("c")
    index = new(max_keys: 2) |> Index.remember(a) |> Index.remember(b)
    assert Index.lookup(index, a.kind, a.key) == [a]
    index = Index.remember(index, c)
    assert Index.lookup(index, a.kind, a.key) == []

    index =
      new(max_keys: 2)
      |> Index.remember(a)
      |> Index.remember(b)
      |> Index.remember(a)
      |> Index.remember(c)

    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.lookup(index, b.kind, b.key) == []
  end

  test "candidates are bounded, deduplicated, and removed individually" do
    a = location("key", "a")
    b = location("key", "b")
    c = location("key", "c")
    index = new(max_locations: 2) |> Index.remember(a) |> Index.remember(b) |> Index.remember(c)
    assert Index.lookup(index, a.kind, a.key) == [c, b]
    index = Index.remember(index, b)
    assert Index.lookup(index, a.kind, a.key) == [b, c]
    index = Index.forget(index, b)
    assert Index.lookup(index, a.kind, a.key) == [c]
    index = Index.forget(index, c)
    assert Index.lookup(index, a.kind, a.key) == []
    assert Index.stats(index).bytes == 0
  end

  test "namespaces do not alias and oversized hints do not displace retained keys" do
    a = location("a")
    source = location("a", "a", :sources)
    index = new(max_bytes: 1_024) |> Index.remember(a) |> Index.remember(source)
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.lookup(index, source.kind, source.key) == [source]
    huge = Partition.location(String.duplicate("x", 2_000), :outputs, "huge", "generation")
    index = Index.remember(index, huge)
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.stats(index).keys == 2
  end

  test "warming uses a fraction of capacity and cannot evict hot keys" do
    a = location("a")
    b = location("b")
    c = location("c")
    d = location("d")

    index =
      new(max_keys: 4, warm_fraction: 0.25) |> Index.remember(a) |> Index.warm(b) |> Index.warm(c)

    assert Index.lookup(index, b.kind, b.key) == []
    assert Index.lookup(index, c.kind, c.key) == [c]
    assert Index.stats(index).warm_keys == 1
    index = index |> Index.remember(b) |> Index.remember(d)
    index = Index.warm(index, location("e"))
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.lookup(index, c.kind, c.key) == []
    assert Index.stats(index).keys == 4
    index = Index.remember(index, location("f"))
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.stats(index).warm_keys == 0
  end

  test "warm updates never refresh or replace an existing hot key" do
    a = location("a")
    b = location("b")
    index = new(max_keys: 2, warm_fraction: 0.5) |> Index.remember(a) |> Index.remember(b)
    index = index |> Index.warm(location("a", "another")) |> Index.warm(location("c"))
    assert Index.lookup(index, a.kind, a.key) == [a]
    assert Index.stats(index).warm_keys == 0
    index = Index.remember(index, location("d"))
    assert Index.lookup(index, a.kind, a.key) == []
  end

  test "an actual hit promotes a warmed entry without synthetic frequency" do
    a = location("a")
    index = new(max_keys: 4, warm_fraction: 0.25) |> Index.warm(a)
    assert Index.stats(index).warm_keys == 1
    index = Index.remember(index, a)
    assert Index.stats(index).warm_keys == 0
    assert Index.lookup(index, a.kind, a.key) == [a]
  end

  property "mixed warming and demand stay within count, payload, and candidate budgets" do
    check all operations <-
                list_of(tuple({member_of([:remember, :warm, :forget]), integer(0..12)}),
                  max_length: 100
                ) do
      index =
        Enum.reduce(
          operations,
          new(max_keys: 4, max_bytes: 2_048, max_locations: 2, warm_fraction: 0.25),
          fn {operation, key}, index ->
            location = location(Integer.to_string(key), Integer.to_string(rem(key, 3)))
            index = apply(Index, operation, [index, location])
            stats = Index.stats(index)
            assert stats.keys <= 4
            assert stats.bytes <= 2_048
            assert stats.warm_keys <= 1
            assert stats.warm_bytes <= 512
            assert length(Index.lookup(index, location.kind, location.key)) <= 2
            index
          end
        )

      assert Index.stats(index).keys <= 4
    end
  end

  defp new(opts),
    do:
      Index.new(
        Keyword.merge(
          [max_keys: 8, max_bytes: 8_192, max_locations: 2, warm_fraction: 0.25],
          opts
        )
      )

  defp location(key, generation \\ "a", kind \\ :outputs),
    do: Partition.location("/shared/partitions/writer/#{kind}/#{key}", kind, key, generation)
end
