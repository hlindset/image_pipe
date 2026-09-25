defmodule ImagePipe.Cache.SharedFileSystem.RetentionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Cache.SharedFileSystem.{Partition, Retention}

  test "real demand drives cost-aware main admission and exact victims" do
    a = descriptor("a", 40)
    b = descriptor("b", 40)
    c = descriptor("c", 40)
    state = demand(new(), a, 5)
    {:admit, state, []} = Retention.offer(state, a)
    state = demand(state, b, 1)
    {:admit, state, []} = Retention.offer(state, b)
    state = demand(state, a, 1)
    state = demand(state, c, 1)
    assert {:reject, :low_value, ^state} = Retention.offer(state, c)
    state = demand(state, c, 1)
    assert {:admit, state, [^b]} = Retention.offer(state, c)
    assert Retention.stats(state).bytes == 80
    assert Retention.retained(state, :outputs, a.location.key) == a
    assert Retention.retained(state, :outputs, b.location.key) == nil
  end

  test "small scan entries compete through the window without displacing frequent main entries" do
    hot = descriptor("hot", 8)
    state = demand(new(max_bytes: 10), hot, 5)
    {:admit, state, []} = Retention.offer(state, hot)
    first = descriptor("first", 1)
    second = descriptor("second", 1)
    third = descriptor("third", 1)
    {:admit, state, []} = Retention.offer(demand(state, first, 1), first)
    {:admit, state, []} = Retention.offer(demand(state, second, 1), second)
    assert {:admit, state, [^first]} = Retention.offer(demand(state, third, 1), third)
    assert Retention.retained(state, :outputs, hot.location.key) == hot
    assert Retention.stats(state).bytes == 10
  end

  test "expensive work can outrank a more frequent but cheap victim" do
    cheap = descriptor("cheap", 80)
    costly = %{descriptor("costly", 80) | cost_us: 10_000}
    {:admit, state, []} = Retention.offer(demand(new(), cheap, 5), cheap)
    assert {:admit, _state, [^cheap]} = Retention.offer(demand(state, costly, 1), costly)
  end

  test "a candidate discarded by its own window transition is rejected before publication" do
    hot = descriptor("hot", 80)
    {:admit, state, []} = Retention.offer(demand(new(max_entries: 1), hot, 5), hot)
    small = descriptor("small", 1)
    state = demand(state, small, 1)
    assert {:reject, :low_value, ^state} = Retention.offer(state, small)
  end

  test "rejected replacement keeps the existing generation and delayed forgetting is scoped" do
    old = descriptor("key", 40)
    {:admit, state, []} = Retention.offer(new(), old)
    oversized = %{old | size_bytes: 101}
    assert {:reject, :over_cap, ^state} = Retention.offer(state, oversized)
    replacement = descriptor("key", 40, :outputs, "replacement")
    assert {:admit, state, [^old]} = Retention.offer(state, replacement)
    state = Retention.forget(state, old)
    assert Retention.retained(state, :outputs, old.location.key) == replacement
    assert Retention.stats(Retention.forget(state, replacement)).bytes == 0
  end

  test "namespace isolation, entry limits and bounded victim fanout" do
    first = descriptor("key", 20)
    other = descriptor("key", 20, :originals)
    {:admit, state, []} = Retention.offer(new(max_entries: 2), first)
    {:admit, state, []} = Retention.offer(state, other)
    assert Retention.retained(state, :outputs, first.location.key) == first
    assert Retention.retained(state, :originals, other.location.key) == other
    assert Retention.stats(state).entries == 2

    state =
      Enum.reduce(1..4, new(max_victims: 1), fn n, state ->
        {:admit, next, []} = Retention.offer(state, descriptor(Integer.to_string(n), 20))
        next
      end)

    large = descriptor("large", 70)
    state = demand(state, large, 20)
    assert {:reject, :victim_limit_exceeded, ^state} = Retention.offer(state, large)
  end

  test "ranking useful retained entries never synthesizes demand" do
    hot = descriptor("hot", 40)
    cold = descriptor("cold", 40)
    {:admit, state, []} = Retention.offer(demand(new(), hot, 4), hot)
    {:admit, state, []} = Retention.offer(demand(state, cold, 1), cold)
    state = demand(state, hot, 1)
    assert [^hot] = Retention.ranked(state, 1)
    assert Retention.stats(state).protected_bytes == 40
    candidate = descriptor("candidate", 40)
    state = demand(state, candidate, 1)
    assert {:reject, :low_value, ^state} = Retention.offer(state, candidate)
    assert [^hot, ^cold] = Retention.ranked(state, 10)
    assert {:reject, :low_value, ^state} = Retention.offer(state, candidate)
  end

  property "mixed demand, admission and retirement stay within logical byte and entry budgets" do
    check all operations <-
                list_of(
                  tuple({member_of([:request, :offer, :forget]), integer(0..8), integer(1..90)}),
                  max_length: 100
                ) do
      Enum.reduce(operations, new(max_entries: 5, max_victims: 4), fn {operation, key, size},
                                                                      state ->
        descriptor = descriptor(Integer.to_string(key), size)

        next =
          case operation do
            :request ->
              demand(state, descriptor, 1)

            :forget ->
              Retention.forget(state, descriptor)

            :offer ->
              case Retention.offer(state, descriptor) do
                {:admit, next, victims} ->
                  assert Retention.retained(
                           next,
                           descriptor.location.kind,
                           descriptor.location.key
                         ) ==
                           descriptor

                  assert length(victims) <= 5
                  next

                {:reject, _reason, unchanged} ->
                  assert unchanged == state
                  unchanged
              end
          end

        stats = Retention.stats(next)
        assert stats.bytes <= 100
        assert stats.entries <= 5
        assert stats.bytes == Enum.sum(Enum.map(Retention.ranked(next, 100), & &1.size_bytes))
        next
      end)
    end
  end

  defp new(opts \\ []) do
    Retention.new(
      Keyword.merge(
        [
          max_bytes: 100,
          window_ratio: 0.2,
          protected_ratio: 0.8,
          max_entries: 100,
          max_victims: 8,
          sketch: [depth: 4, width: 128, sample_size: 32]
        ],
        opts
      )
    )
  end

  defp descriptor(key, size, kind \\ :outputs, generation \\ "generation") do
    key = Base.encode16(:crypto.hash(:sha256, key), case: :lower)
    generation = Base.encode16(:crypto.hash(:md5, generation), case: :lower)

    location =
      Partition.location("/shared/partitions/writer/#{kind}/#{key}", kind, key, generation)

    Retention.descriptor(location, size, :crypto.hash(:sha256, key), 0)
  end

  defp demand(state, descriptor, count),
    do:
      Enum.reduce(1..count, state, fn _, state ->
        Retention.request(state, descriptor.location.kind, descriptor.location.key)
      end)
end
