defmodule ImagePipe.Cache.FileSystem.PolicyTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Cache.FileSystem.Policy

  defp descriptor(opts) do
    %{
      key_hash: Keyword.get(opts, :key_hash, "h"),
      size_bytes: Keyword.fetch!(opts, :size_bytes),
      body_sha256: Keyword.get(opts, :body_sha256, "s"),
      cost_us: Keyword.get(opts, :cost_us, 1000)
    }
  end

  describe "score/2" do
    test "is a float for normal inputs" do
      d = descriptor(size_bytes: 1_000, cost_us: 10_000)
      assert is_float(Policy.score(d, _freq = 3))
    end

    test "captures value-per-byte" do
      small_expensive = descriptor(size_bytes: 1_000, cost_us: 50_000)
      large_cheap = descriptor(size_bytes: 1_000_000, cost_us: 50_000)

      assert Policy.score(small_expensive, 1) > Policy.score(large_cheap, 1)
    end

    test "cost_us=0 falls back to size_bytes (frequency-only scoring)" do
      d = descriptor(size_bytes: 1_000_000, cost_us: 0)
      # Expected: score = freq * size / size = freq (as float)
      assert_in_delta Policy.score(d, 5), 5.0, 0.0001
    end

    test "handles size_bytes=0 safely (uses max(size, 1))" do
      d = descriptor(size_bytes: 0, cost_us: 1000)
      assert is_float(Policy.score(d, 1))
    end
  end

  describe "weighted_avg_score/2" do
    test "returns 0.0 for empty victim list" do
      assert Policy.weighted_avg_score([], fn _ -> 0 end) == 0.0
    end

    test "computes value-per-byte across a victim set" do
      v1 = descriptor(size_bytes: 100, cost_us: 1_000)
      v2 = descriptor(size_bytes: 200, cost_us: 2_000)
      freq_fn = fn _ -> 1 end

      # sum(freq * cost) = 1*1000 + 1*2000 = 3000
      # sum(size) = 300
      # weighted_avg = 3000/300 = 10.0
      assert_in_delta Policy.weighted_avg_score([v1, v2], freq_fn), 10.0, 0.0001
    end
  end

  describe "victim_walk/4" do
    test "walks probationary LRU outward until enough bytes" do
      probationary = [
        descriptor(key_hash: "lru", size_bytes: 100),
        descriptor(key_hash: "mid", size_bytes: 100),
        descriptor(key_hash: "mru", size_bytes: 100)
      ]

      protected = []

      assert {:ok, [v1]} = Policy.victim_walk(probationary, protected, 100, 64)
      assert v1.key_hash == "lru"

      assert {:ok, [v1, v2]} = Policy.victim_walk(probationary, protected, 150, 64)
      assert [v1.key_hash, v2.key_hash] == ["lru", "mid"]
    end

    test "extends into protected LRU when probationary exhausted" do
      probationary = [descriptor(key_hash: "p_lru", size_bytes: 100)]
      protected = [descriptor(key_hash: "prot_lru", size_bytes: 200)]

      assert {:ok, victims} = Policy.victim_walk(probationary, protected, 250, 64)
      assert Enum.map(victims, & &1.key_hash) == ["p_lru", "prot_lru"]
    end

    test "cross-queue walk succeeds when total victims are within the limit" do
      # Regression: the probationary victim must not be double-counted against
      # the limit when extending into protected. 1 probationary + 1 protected =
      # 2 victims, exactly at limit 2 — must succeed, not :victim_limit_exceeded.
      probationary = [descriptor(key_hash: "p_lru", size_bytes: 100)]
      protected = [descriptor(key_hash: "prot_lru", size_bytes: 200)]

      assert {:ok, victims} = Policy.victim_walk(probationary, protected, 250, 2)
      assert Enum.map(victims, & &1.key_hash) == ["p_lru", "prot_lru"]
    end

    test "limit caps the total victim count across both queues" do
      # 2 probationary + 1 protected would be needed to free 250 bytes, but the
      # limit of 2 covers only the probationary victims — extending into
      # protected would exceed it.
      probationary = [
        descriptor(key_hash: "p1", size_bytes: 100),
        descriptor(key_hash: "p2", size_bytes: 100)
      ]

      protected = [descriptor(key_hash: "prot", size_bytes: 100)]

      assert {:error, :victim_limit_exceeded} =
               Policy.victim_walk(probationary, protected, 250, 2)
    end

    test "returns :no_evictable_victims when both queues together cannot free enough" do
      probationary = [descriptor(size_bytes: 50)]
      protected = [descriptor(size_bytes: 50)]

      assert {:error, :no_evictable_victims} =
               Policy.victim_walk(probationary, protected, 200, 64)
    end

    test "returns :victim_limit_exceeded when freeing enough bytes requires more victims than the limit" do
      # 10 victims × 100 bytes = 1000 bytes available, but limit is 3.
      probationary = for i <- 1..10, do: descriptor(key_hash: "k#{i}", size_bytes: 100)

      assert {:error, :victim_limit_exceeded} =
               Policy.victim_walk(probationary, [], 500, 3)
    end
  end

  describe "admit?/3" do
    test "admits when candidate score exceeds weighted-average victim score" do
      candidate = descriptor(key_hash: "c", size_bytes: 100, cost_us: 50_000)
      victims = [descriptor(key_hash: "v", size_bytes: 100, cost_us: 1_000)]
      freq_fn = fn _ -> 1 end

      assert Policy.admit?(candidate, victims, freq_fn) == true
    end

    test "rejects when candidate score is below weighted-average victim score" do
      candidate = descriptor(key_hash: "c", size_bytes: 100, cost_us: 1_000)
      victims = [descriptor(key_hash: "v", size_bytes: 100, cost_us: 50_000)]
      freq_fn = fn _ -> 1 end

      assert Policy.admit?(candidate, victims, freq_fn) == false
    end

    test "admits unconditionally when victim list is empty (no comparison needed)" do
      candidate = descriptor(size_bytes: 100, cost_us: 1)
      assert Policy.admit?(candidate, [], fn _ -> 0 end) == true
    end
  end
end
