defmodule ImagePipe.Test.ImgproxyBench.Merge do
  @moduledoc """
  Merges the `results.json` of `mix imgproxy.bench --compare --shard I/N`
  runs into one result, as if one machine had run every round.

  Each shard timed every image on its own machine, so its ratios stand on
  their own. The merge puts every case's and burst's rounds in round order,
  keeps a case only if no shard reports it as a mismatch, and lists each
  shard's environment under `"shards"`.
  """
  use Boundary, top_level?: true, deps: []

  @spec merge([map()]) :: map()
  def merge([_ | _] = shards) do
    shards = Enum.sort_by(shards, &hd(&1["shard"]["rounds"]))
    check_same_selection!(shards)

    mismatches =
      shards |> Enum.flat_map(& &1["mismatches"]) |> Enum.uniq_by(& &1["id"])

    mismatched = MapSet.new(mismatches, & &1["id"])
    [first | _] = shards

    %{
      "mode" => "compare",
      "candidate" => first["candidate"],
      "against" => first["against"],
      "environment" => environment(shards),
      "cases" =>
        first["cases"]
        |> Enum.reject(&(&1["id"] in mismatched))
        |> Enum.map(&merge_entry(&1, shards, "cases")),
      "bursts" => Enum.map(first["bursts"], &merge_entry(&1, shards, "bursts")),
      "baseline" =>
        Map.new(first["baseline"], fn {key, _rounds} ->
          {key, in_round_order(shards, & &1["baseline"][key])}
        end),
      "mismatches" => mismatches
    }
  end

  # Shards that selected different cases or images can't be merged.
  defp check_same_selection!(shards) do
    selections =
      shards
      |> Enum.map(fn s ->
        ids = Enum.map(s["cases"] ++ s["mismatches"] ++ s["bursts"], & &1["id"])
        {s["candidate"], s["against"], Enum.sort(ids), s["shard"]["count"]}
      end)
      |> Enum.uniq()

    if length(selections) > 1 do
      raise ArgumentError, "the shards ran different cases or images"
    end
  end

  # A case or burst with every shard's rounds for each image, in round order.
  # A case that mismatched on no shard is in every shard's `"cases"`.
  defp merge_entry(entry, shards, list) do
    entries = Enum.map(shards, fn s -> Enum.find(s[list], &(&1["id"] == entry["id"])) end)

    rounds =
      Map.new(entry["rounds"], fn {key, _rounds} ->
        {key, in_round_order(Enum.zip(shards, entries), fn {_s, e} -> e["rounds"][key] end)}
      end)

    merged = Map.put(entry, "rounds", rounds)

    case Map.fetch(entry, "window_s") do
      {:ok, _window} -> Map.put(merged, "window_s", Enum.map(entries, & &1["window_s"]))
      :error -> merged
    end
  end

  # Pairs each shard's per-round values with its round numbers and sorts them
  # by round. `items` are shards, or `{shard, entry}` pairs.
  defp in_round_order(items, values) do
    items
    |> Enum.flat_map(fn item -> Enum.zip(round_numbers(item), values.(item)) end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp round_numbers({shard, _entry}), do: round_numbers(shard)
  defp round_numbers(shard), do: shard["shard"]["rounds"]

  defp environment([first | _] = shards) do
    first["environment"]
    |> Map.put("rounds", shards |> Enum.map(&length(&1["shard"]["rounds"])) |> Enum.sum())
    |> Map.put("shards", Enum.map(shards, &Map.put(&1["environment"], "shard", &1["shard"])))
  end
end
