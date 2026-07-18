defmodule ImagePipe.Test.TwicpicsDifferential.ConstellationsTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Parser.TwicPics
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

    assert [
             %{
               id: "resize_shadow_relative_then_absolute",
               triage: %{reason: reason, issue: issue}
             }
           ] = Enum.filter(constellations, &Map.has_key?(&1, :triage))

    assert is_binary(reason) and String.trim(reason) != ""
    assert issue == 464
    assert issue > 0

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

  test "every non-triaged chain parses via ImagePipe.Parser.TwicPics" do
    for c <- Constellations.all(), is_nil(c[:triage]) do
      assert {:ok, _plan} = parse(Constellations.twicpics_path(c)),
             "chain failed to parse: #{c.id} (#{c.chain})"
    end
  end

  # `ImagePipe.Parser.TwicPics.parse/2` takes (%Plug.Conn{}, opts); `Plug.Test.conn/2`
  # already populates path_info + the `twic` query param the parser reads. The opts
  # must carry the resolved `:twicpics` config (parse/2 reads it for output defaults).
  defp parse(path), do: TwicPics.parse(Plug.Test.conn(:get, path), TwicPics.validate_options!([]))
end
