defmodule ImagePipe.Test.TwicpicsDifferential.ConstellationsTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Dialect.TwicPics
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, SourceInventory}

  test "ids are unique" do
    ids = Enum.map(Constellations.all(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "authored verdict and quarantine census is explicit" do
    constellations = Constellations.all()

    assert length(constellations) == 39
    assert Enum.count(constellations, &(&1.verdict == :equal)) == 34
    assert Enum.count(constellations, &(&1.verdict == :diverges)) == 5

    # #464 closed in Phase 2B: the shadow case is now an ordinary :equal lane case
    # matching its committed 340x340 fixture, so no constellation is quarantined.
    assert [] = Enum.filter(constellations, &Map.has_key?(&1, :triage))

    for constellation <- constellations, constellation.verdict == :diverges do
      assert %{max_delta: max_delta, outliers: outliers} = constellation.divergence
      assert %Range{first: max_first, last: max_last} = max_delta
      assert %Range{first: outlier_first, last: outlier_last} = outliers
      assert max_first < max_last
      assert outlier_first < outlier_last
    end
  end

  # Lives here (not in the source-inventory drift test) because it needs Constellations.
  test "every constellation source is inventoried" do
    inv = SourceInventory.all() |> Enum.map(& &1.file) |> MapSet.new()

    for c <- Constellations.all() do
      assert MapSet.member?(inv, Constellations.source_file(c)),
             "uninventoried source for #{c.id}"
    end
  end

  test "twicpics_path builds the ?twic=v1 form with the pinned suffix" do
    c = %{id: "x", source: :grid_4x4, chain: "cover=200x100", verdict: :equal, group: :cover}
    assert Constellations.twicpics_path(c) == "/grid_4x4.png?twic=v1/cover=200x100/output=png"
  end

  test "every non-triaged chain parses via ImagePipe.Dialect.TwicPics" do
    dialect_opts = TwicPics.validate_config!([])

    for c <- Constellations.all(), is_nil(c[:triage]) do
      assert {:ok, _request} = parse(Constellations.twicpics_path(c), dialect_opts),
             "chain failed to parse: #{c.id} (#{c.chain})"
    end
  end

  defp parse(path, dialect_opts) do
    {result, _span_metadata} = TwicPics.parse(Plug.Test.conn(:get, path), dialect_opts)
    result
  end
end
