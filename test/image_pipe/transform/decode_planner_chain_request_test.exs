defmodule ImagePipe.Transform.DecodePlannerChainRequestTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Transform.DecodePlanner

  # The declarative tier plans its decode through the %Request{} entry point,
  # but IIIF's shrink-on-load behavior is defined by the chain entry point.
  # These must produce IDENTICAL load options for every constructible chain.
  defp equivalent?(chain, format, dims, exif_qt?, auto_rotate?) do
    from_chain = DecodePlanner.open_options(chain, format, dims, exif_qt?, auto_rotate?)

    from_request =
      chain
      |> DecodePlanner.request_from_chain(dims, exif_qt? and auto_rotate?)
      |> DecodePlanner.open_options_for(format, dims, exif_qt?, auto_rotate?)

    from_chain == from_request
  end

  defp resize!(mode, w, h, opts \\ []) do
    {:ok, op} = Operation.resize(mode, w, h, opts)
    op
  end

  defp crop_region!(w, h) do
    {:ok, op} =
      Operation.crop_region({:px, 0}, {:px, 0}, {:px, w}, {:px, h}, on_out_of_bounds: :reject)

    op
  end

  defp rotate!(angle) do
    {:ok, op} = Operation.rotate(angle, false)
    op
  end

  defp trim! do
    {:ok, op} =
      Operation.trim(threshold: 10, background: :auto, equal_hor: false, equal_ver: false)

    op
  end

  describe "request_from_chain/3 reproduces open_options/5" do
    test "no resize" do
      assert equivalent?([%Gray{}], :jpeg, {4000, 3000}, false, true)
    end

    test "single-axis pixel resize across formats" do
      chain = [resize!(:fit, {:px, 400}, :auto)]

      for format <- [:jpeg, :webp, :png, :avif] do
        assert equivalent?(chain, format, {4000, 3000}, false, true)
      end
    end

    test "crop before resize narrows the extent feeding the shrink" do
      chain = [crop_region!(800, 600), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "min_width forbids shrink" do
      chain = [resize!(:fit, {:px, 400}, {:px, 300}, min_width: {:px, 100})]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "trim disables shrink" do
      chain = [trim!(), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
    end

    test "quarter-turn rotate before the resize swaps the shrink axes" do
      chain = [rotate!(90), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, false, true)
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    # %Rotate{} accepts any angle in [0, 360] (plan/operation.ex normalizes a
    # whole-valued float like 90.0 down to the integer 90, but leaves a
    # fractional float such as 30.5 as a float), and the IIIF grammar parses
    # arbitrary floats. A naive boolean XOR of the EXIF and user turns diverges
    # from the chain path's `rem(sum, 180) == 90` here. Angles are kept to
    # integers: the chain path's own `user_rotate_angle_before_resize/1` folds
    # angles with `rem/2`, which is integer-only in Erlang/Elixir and raises
    # `ArithmeticError` on a fractional float (verified directly: even
    # `DecodePlanner.open_options/5` itself raises given a chain containing
    # `%Rotate{angle: 30.5}`). So a fractional angle is already unsupported by
    # the chain entry point this test compares against, independent of
    # `request_from_chain/3` — this is not a case being carved out of a
    # divergence, it is an input neither path can accept.
    test "an arbitrary-angle rotate before the resize agrees on the axis choice" do
      for angle <- [45, 30, 135, 200, 359] do
        chain = [rotate!(angle), resize!(:fit, {:px, 400}, :auto)]
        assert equivalent?(chain, :jpeg, {4000, 3000}, true, true), "angle #{angle}"
        assert equivalent?(chain, :jpeg, {4000, 3000}, false, true), "angle #{angle}"
      end
    end

    test "two rotates before the resize accumulate" do
      chain = [rotate!(45), rotate!(45), resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    test "flip contributes no turn" do
      chain = [%Flip{axis: :horizontal}, resize!(:fit, {:px, 400}, :auto)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end

    test "a rotate AFTER the resize contributes no turn (the IIIF operation order)" do
      chain = [resize!(:fit, {:px, 400}, :auto), rotate!(90)]
      assert equivalent?(chain, :jpeg, {4000, 3000}, true, true)
    end
  end

  property "the two entry points agree over IIIF-shaped chains" do
    check all(
            src_w <- integer(64..6000),
            src_h <- integer(64..6000),
            target_w <- one_of([constant(nil), integer(1..4000)]),
            target_h <- one_of([constant(nil), integer(1..4000)]),
            crop <- one_of([constant(nil), tuple({integer(1..6000), integer(1..6000)})]),
            # Restricted to integers: the chain path's own
            # `user_rotate_angle_before_resize/1` folds rotate angles with
            # `rem/2`, which is integer-only in Erlang/Elixir and raises
            # `ArithmeticError` given a fractional float angle — verified
            # directly against `DecodePlanner.open_options/5` itself, so a
            # fractional angle is unsupported by the very entry point this
            # property compares against, independent of `request_from_chain/3`.
            angle <- one_of([constant(0), member_of([90, 180, 270]), integer(1..359)]),
            format <- member_of([:jpeg, :webp, :png, :avif]),
            exif_qt? <- boolean(),
            auto_rotate? <- boolean(),
            max_runs: 300
          ) do
      chain = rotate_ops(angle) ++ crop_ops(crop) ++ resize_ops(target_w, target_h)
      assert equivalent?(chain, format, {src_w, src_h}, exif_qt?, auto_rotate?)
    end
  end

  defp rotate_ops(0), do: []
  defp rotate_ops(angle), do: [rotate!(angle)]

  defp crop_ops(nil), do: []
  defp crop_ops({w, h}), do: [crop_region!(w, h)]

  defp resize_ops(nil, nil), do: []
  defp resize_ops(w, h), do: [resize!(:fit, axis(w), axis(h))]

  defp axis(nil), do: :auto
  defp axis(n), do: {:px, n}
end
