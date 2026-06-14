defmodule ImagePipe.Plan.OperationResizeBoundsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Resize

  test "resize/4 accepts and stores max_width/max_height/max_area" do
    assert {:ok, %Resize{max_width: 2000, max_height: 1500, max_area: 3_000_000}} =
             Operation.resize(:fit, :auto, :auto,
               max_width: 2000,
               max_height: 1500,
               max_area: 3_000_000
             )
  end

  test "resize/4 defaults the three bounds to nil" do
    assert {:ok, %Resize{max_width: nil, max_height: nil, max_area: nil}} =
             Operation.resize(:fit, :auto, :auto)
  end

  test "resize/4 accepts nil bounds explicitly (parser threads nils uniformly)" do
    assert {:ok, %Resize{max_width: nil, max_height: nil, max_area: nil}} =
             Operation.resize(:fit, :auto, :auto, max_width: nil, max_height: nil, max_area: nil)
  end

  test "resize/4 rejects a non-positive or non-integer bound" do
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_width: 0)
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_height: -5)
    assert {:error, _} = Operation.resize(:fit, :auto, :auto, max_area: 1.5)
  end

  test "semantic? accepts a Resize with valid bounds and rejects bad ones" do
    {:ok, %Resize{} = ok} = Operation.resize(:fit, :auto, :auto, max_width: 2000)
    assert Operation.semantic?(ok)

    bad = %Resize{ok | max_width: 0}
    refute Operation.semantic?(bad)
  end
end
