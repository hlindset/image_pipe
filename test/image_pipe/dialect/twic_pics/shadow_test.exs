defmodule ImagePipe.Dialect.TwicPics.ShadowTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Dialect.TwicPics.Shadow
  alias ImagePipe.Plan.Operation.Resize
  alias ImagePipe.Plan.Source.Path

  # Steps come from the real RequestBuilder producer, never hand-built structs.
  defp steps(chain) do
    {:ok, request} =
      RequestBuilder.build(%Path{segments: ["x.png"]}, chain, ImagePipe.Config.resolve!([]))

    request.steps
  end

  defp exec(chain), do: Shadow.execution_steps(steps(chain))

  # The rewrite is proven only by the documented resize=50p/resize=340 example
  # (TwicPics transformations reference). It must never generalize to a last-wins
  # rule, so every collapsing case has an absolute later resize and an aspect-
  # preserving relative earlier resize, and every non-collapsing case is asserted
  # to stay literal.
  describe "upstream-proven resize shadow" do
    test "an absolute resize shadows an immediately-preceding relative resize" do
      # resize=50p/resize=340 -> resize=340; TwicPics "ignores the first resize".
      assert [{:operation, %Resize{mode: :fit, width: {:px, 340}, height: :auto}}] =
               exec([{"resize", "50p"}, {"resize", "340"}])
    end

    test "a run of preceding relative resizes collapses to fixpoint" do
      assert [{:operation, %Resize{width: {:px, 340}}}] =
               exec([{"resize", "25p"}, {"resize", "50p"}, {"resize", "340"}])
    end

    test "an absolute WxH resize shadows a preceding relative resize" do
      assert [{:operation, %Resize{mode: :stretch, width: {:px, 200}, height: {:px, 100}}}] =
               exec([{"resize", "50p"}, {"resize", "200x100"}])
    end
  end

  describe "non-shadowing chains stay literal" do
    test "a later relative resize composes rather than shadowing (resize=340/resize=50p)" do
      assert [
               {:operation, %Resize{width: {:px, 340}}},
               {:operation, %Resize{width: {:ratio, 1, 2}}}
             ] = exec([{"resize", "340"}, {"resize", "50p"}])
    end

    test "two relative resizes both survive (running-dimension composition)" do
      assert [
               {:operation, %Resize{width: {:ratio, 1, 2}}},
               {:operation, %Resize{width: {:ratio, 1, 4}}}
             ] = exec([{"resize", "50p"}, {"resize", "25p"}])
    end

    test "an intervening focus keeps the earlier resize observable" do
      assert [
               {:operation, %Resize{width: {:ratio, 1, 2}}},
               {:set_focus, _operand},
               {:operation, %Resize{width: {:px, 340}}}
             ] = exec([{"resize", "50p"}, {"focus", "10x10"}, {"resize", "340"}])
    end

    test "cover is not a plain resize and never shadows a preceding resize" do
      assert [
               {:operation, %Resize{width: {:ratio, 1, 2}}},
               {:focused, %Resize{mode: :cover}}
             ] = exec([{"resize", "50p"}, {"cover", "340x340"}])
    end

    test "a dual-axis contain (conditional fit) never shadows a preceding resize" do
      # contain=WxH lowers to a dual-axis :fit whose output depends on the input
      # frame (min-scale + no-enlarge), so it is not absolute and cannot shadow.
      assert [
               {:operation, %Resize{width: {:ratio, 1, 4}}},
               {:operation, %Resize{mode: :fit, width: {:px, 340}, height: {:px, 200}}}
             ] = exec([{"resize", "25p"}, {"contain", "340x200"}])
    end

    test "inside (fit + letterbox) never shadows a preceding resize" do
      # inside=WxH pushes the same dual-axis :fit (plus a canvas), so the earlier
      # relative resize stays observable through it.
      result = exec([{"resize", "50p"}, {"inside", "340x200"}])
      assert [{:operation, %Resize{mode: :fit, width: {:ratio, 1, 2}}} | _rest] = result
      assert length(result) == 3
    end

    test "an aspect-changing absolute earlier resize is not shadowed" do
      # resize=200x300 changes the aspect ratio, so the later single-axis fit
      # resize is not proven independent of it upstream; the pair stays literal.
      assert [
               {:operation, %Resize{mode: :stretch, width: {:px, 200}, height: {:px, 300}}},
               {:operation, %Resize{mode: :fit, width: {:px, 340}, height: :auto}}
             ] = exec([{"resize", "200x300"}, {"resize", "340"}])
    end
  end
end
