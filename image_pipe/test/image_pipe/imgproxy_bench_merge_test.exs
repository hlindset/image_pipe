defmodule ImagePipe.ImgproxyBenchMergeTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.ImgproxyBench.Merge

  # Two shards of a four-round run: shard 1 ran rounds 1 and 3, shard 2
  # rounds 2 and 4. Each round's value is its round number, so order shows.
  defp shard(index, opts) do
    rounds = [index, index + 2]
    timed = Keyword.get(opts, :timed, ["a", "b"])
    mismatched = Keyword.get(opts, :mismatched, [])
    per_image = fn -> %{"candidate" => rounds, "base" => Enum.map(rounds, &(&1 * 10))} end

    %{
      "mode" => "compare",
      "shard" => %{"count" => 2, "rounds" => rounds},
      "candidate" => "candidate",
      "against" => ["base"],
      "environment" => %{"rounds" => 2, "docker" => "runner #{index}"},
      "cases" =>
        for(id <- timed, do: %{"id" => id, "window_s" => index, "rounds" => per_image.()}),
      "bursts" => [%{"id" => "burst", "rounds" => per_image.()}],
      "baseline" => per_image.(),
      "mismatches" => for(id <- mismatched, do: %{"id" => id, "responses" => %{}})
    }
  end

  test "puts every shard's rounds in round order" do
    merged = Merge.merge([shard(2, []), shard(1, [])])

    [a, b] = merged["cases"]
    assert a["rounds"] == %{"candidate" => [1, 2, 3, 4], "base" => [10, 20, 30, 40]}
    assert b["rounds"]["candidate"] == [1, 2, 3, 4]
    assert a["window_s"] == [1, 2]
    assert hd(merged["bursts"])["rounds"]["candidate"] == [1, 2, 3, 4]
    assert merged["baseline"]["base"] == [10, 20, 30, 40]
    assert merged["environment"]["rounds"] == 4

    assert Enum.map(merged["environment"]["shards"], & &1["docker"]) ==
             ["runner 1", "runner 2"]
  end

  test "drops a case that mismatched on any shard" do
    merged = Merge.merge([shard(1, []), shard(2, timed: ["a"], mismatched: ["b"])])

    assert Enum.map(merged["cases"], & &1["id"]) == ["a"]
    assert Enum.map(merged["mismatches"], & &1["id"]) == ["b"]
  end

  test "refuses shards that ran different cases" do
    assert_raise ArgumentError, fn ->
      Merge.merge([shard(1, []), shard(2, timed: ["a"])])
    end
  end
end
