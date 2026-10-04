defmodule ImagePipe.Plan.Output.QualitySearchTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Plan.Output.QualitySearch

  defp config(extra \\ []) do
    Keyword.merge(
      [autoquality: false, autoquality_target: 75, autoquality_max_resolution: 0],
      extra
    )
  end

  test "an unset request follows the host toggle" do
    assert QualitySearch.resolve(nil, config()) == :none

    assert QualitySearch.resolve(nil, config(autoquality: true)) ==
             %QualitySearch{target: 75.0, max_resolution: 0}
  end

  test "false turns the search off over a host default" do
    assert QualitySearch.resolve(false, config(autoquality: true)) == :none
  end

  test "true uses the host target" do
    assert QualitySearch.resolve(true, config(autoquality_target: 80)) ==
             %QualitySearch{target: 80.0, max_resolution: 0}
  end

  test "a request target wins over the host target" do
    assert QualitySearch.resolve(70.0, config(autoquality_max_resolution: 4)) ==
             %QualitySearch{target: 70.0, max_resolution: 4}
  end
end
