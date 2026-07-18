defmodule ImagePipe.Transform.FocusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.Focus

  describe "rational helpers" do
    test "default carried point is nil and helpers no-op on nil" do
      assert Focus.scale(nil, {:ratio, 1, 2}, {:ratio, 1, 2}) == nil
      assert Focus.translate(nil, -10, -5) == nil
      assert Focus.to_fp(nil, 400, 400) == nil
    end

    test "scale multiplies each axis exactly (rational, no float)" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      scaled = Focus.scale(point, {:ratio, 1, 2}, {:ratio, 1, 2})
      assert scaled == {{:ratio, 100, 1}, {:ratio, 50, 1}}
    end

    test "translate subtracts/adds integer deltas exactly" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      assert Focus.translate(point, -40, -30) == {{:ratio, 160, 1}, {:ratio, 70, 1}}
      # transient negative numerator is allowed (a later canvas +x recovers it)
      assert Focus.translate(point, -300, 0) ==
               {{:ratio, -100, 1}, {:ratio, 100, 1}}
    end
  end

  describe "resolve/3 (set_focus directive unit resolution)" do
    # ctx/1: no orientation, no shrink (storage dims; display is derived internally).
    defp ctx(dims), do: %{storage: dims, decode_shrink: nil}
    defp ctx(dims, shrink), do: %{storage: dims, decode_shrink: shrink}

    test "resolves px against the live frame" do
      assert Focus.resolve({:coord, {:px, 20}, {:px, 10}}, ctx({400, 400}), nil) ==
               {{:ratio, 20, 1}, {:ratio, 10, 1}}
    end

    test "resolves a relative ratio against the live frame" do
      assert Focus.resolve({:coord, {:ratio, 1, 2}, {:ratio, 1, 4}}, ctx({400, 400}), nil) ==
               {{:ratio, 200, 1}, {:ratio, 100, 1}}
    end

    test "clamps positive OOB (px and relative >1) to the far edge (dim-1)" do
      assert Focus.resolve({:coord, {:px, 500}, {:px, 500}}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}

      assert Focus.resolve({:coord, {:ratio, 3, 2}, {:ratio, 3, 2}}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}
    end

    test "resolves anchors to corner/edge points" do
      assert Focus.resolve({:anchor, :left, :top}, ctx({400, 400}), nil) ==
               {{:ratio, 0, 1}, {:ratio, 0, 1}}

      assert Focus.resolve({:anchor, :right, :bottom}, ctx({400, 400}), nil) ==
               {{:ratio, 399, 1}, {:ratio, 399, 1}}

      assert Focus.resolve({:anchor, :center, :center}, ctx({400, 400}), nil) ==
               {{:ratio, 200, 1}, {:ratio, 200, 1}}
    end

    test "bare-pixel focus rescales by decode_shrink; relative/anchor do not" do
      shrunk = ctx({100, 100}, %{w: 4.0, h: 4.0})

      assert Focus.resolve({:coord, {:px, 100}, {:px, 100}}, shrunk, nil) ==
               {{:ratio, 25, 1}, {:ratio, 25, 1}}

      assert Focus.resolve({:coord, {:ratio, 1, 2}, {:ratio, 1, 2}}, shrunk, nil) ==
               {{:ratio, 50, 1}, {:ratio, 50, 1}}
    end
  end

  describe "to_fp/1" do
    test "normalizes to a 0..1 fraction against the live image dims" do
      point = {{:ratio, 200, 1}, {:ratio, 100, 1}}
      assert {:fp, fx, fy} = Focus.to_fp(point, 400, 400)
      assert_in_delta fx, 0.5, 1.0e-9
      assert_in_delta fy, 0.25, 1.0e-9
    end

    test "clamps fp into [0,1]" do
      over = {{:ratio, 500, 1}, {:ratio, 500, 1}}
      assert Focus.to_fp(over, 400, 400) == {:fp, 1.0, 1.0}
      under = {{:ratio, -10, 1}, {:ratio, -10, 1}}
      assert Focus.to_fp(under, 400, 400) == {:fp, 0.0, 0.0}
    end
  end
end
