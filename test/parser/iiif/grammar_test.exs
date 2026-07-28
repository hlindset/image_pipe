defmodule ImagePipe.Parser.IIIF.GrammarTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Dialect.IIIF.Grammar

  test "region" do
    assert Grammar.region("full") == {:ok, :full}
    assert Grammar.region("square") == {:ok, :square}
    assert Grammar.region("0,10,200,300") == {:ok, {:px, 0, 10, 200, 300}}
    assert {:ok, {:pct, {:ratio, 105, 1000}, _, _, _}} = Grammar.region("pct:10.5,0,50,50")
    assert {:error, {:invalid_region, "0,0,0,300"}} = Grammar.region("0,0,0,300")
    assert {:error, {:invalid_region, "garbage"}} = Grammar.region("garbage")
  end

  test "size + ^ upscaling flag" do
    assert Grammar.size("max") == {:ok, {:max, false}}
    assert Grammar.size("^max") == {:ok, {:max, true}}
    assert Grammar.size("200,") == {:ok, {:w, 200, false}}
    assert Grammar.size(",300") == {:ok, {:h, 300, false}}
    assert Grammar.size("200,300") == {:ok, {:wh, 200, 300, false}}
    assert Grammar.size("!200,300") == {:ok, {:confined, 200, 300, false}}
    assert {:ok, {:pct, {:ratio, 50, 100}, false}} = Grammar.size("pct:50")
    assert {:ok, {:pct, {:ratio, 200, 100}, true}} = Grammar.size("^pct:200")
    assert {:error, {:invalid_size, "pct:200"}} = Grammar.size("pct:200")
    assert {:error, {:invalid_size, "0,0"}} = Grammar.size("0,0")
  end

  test "rotation / quality / format" do
    assert Grammar.rotation("0") == {:ok, {false, 0}}
    assert Grammar.rotation("90") == {:ok, {false, 90}}
    assert Grammar.rotation("90.0") == {:ok, {false, 90}}
    assert Grammar.rotation("360") == {:ok, {false, 0}}
    assert Grammar.rotation("45") == {:ok, {false, 45}}
    assert Grammar.rotation("22.5") == {:ok, {false, 22.5}}
    assert Grammar.rotation("!90") == {:ok, {true, 90}}
    assert Grammar.rotation("!0") == {:ok, {true, 0}}
    assert Grammar.rotation("045") == {:ok, {false, 45}}
    assert {:error, {:invalid_rotation, "-5"}} = Grammar.rotation("-5")
    assert {:error, {:invalid_rotation, "361"}} = Grammar.rotation("361")
    assert {:error, {:invalid_rotation, "45."}} = Grammar.rotation("45.")
    assert {:error, {:invalid_rotation, ".5"}} = Grammar.rotation(".5")
    assert {:error, {:invalid_rotation, "45deg"}} = Grammar.rotation("45deg")
    assert {:error, {:invalid_rotation, "+45"}} = Grammar.rotation("+45")
    assert {:error, {:invalid_rotation, " 45"}} = Grammar.rotation(" 45")
    assert {:error, {:invalid_rotation, "!"}} = Grammar.rotation("!")
    assert {:error, {:invalid_rotation, "abc"}} = Grammar.rotation("abc")
    assert Grammar.quality("gray") == {:ok, :gray}
    assert Grammar.quality("bitonal") == {:ok, :bitonal}
    assert {:error, {:invalid_quality, "sepia"}} = Grammar.quality("sepia")
    assert Grammar.format("jpg") == {:ok, :jpg}
    assert {:error, {:invalid_format, "tif"}} = Grammar.format("tif")
  end

  property "pct percentages convert to exact integer ratios" do
    check all n <- integer(0..10_000) do
      decimal = n / 100
      {:ok, {:ratio, num, den}} = Grammar.pct_to_ratio(Float.to_string(decimal))
      assert num / den == decimal
    end
  end
end
