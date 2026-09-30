defmodule ImagePipe.Transform.Operation.TrimTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Color
  alias ImagePipe.Transform.Operation.Trim
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.Operation

  # Builds a `width`x`height` image filled with `bg` ([r,g,b]) with an inner
  # `inner_w`x`inner_h` block of `fg` at (left, top).
  defp bordered(width, height, bg, fg, left, top, inner_w, inner_h) do
    {:ok, canvas} = Operation.black(width, height, bands: 3)
    {:ok, canvas} = Operation.linear(canvas, [1.0, 1.0, 1.0], bg)
    {:ok, block} = Operation.black(inner_w, inner_h, bands: 3)
    {:ok, block} = Operation.linear(block, [1.0, 1.0, 1.0], fg)
    {:ok, composed} = Operation.insert(canvas, block, left, top)
    composed
  end

  defp state(image), do: %State{image: image} |> Map.put(:materialized?, true)

  test "requires materialization" do
    assert Trim.requires_materialization?(%Trim{
             threshold: 10.0,
             background: :auto,
             equal_hor: false,
             equal_ver: false
           })
  end

  test "smart (:auto) trims a uniform border to the inner block" do
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 10, 8, 20, 24)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20
    assert Image.height(out) == 24
  end

  test "explicit color background trims" do
    {:ok, black} = Color.rgb(0, 0, 0)
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 5, 5, 30, 30)
    op = %Trim{threshold: 10.0, background: black, equal_hor: false, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 30
    assert Image.height(out) == 30
  end

  test "uniform image is a no-op (returned unchanged), never an error" do
    {:ok, img} = Operation.black(20, 20, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20
    assert Image.height(out) == 20
  end

  test "equal_hor symmetrizes to the smaller horizontal margin" do
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 4, 4, 20, 32)
    plain = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    equal = %Trim{threshold: 10.0, background: :auto, equal_hor: true, equal_ver: false}
    assert {:ok, %State{image: plain_out}} = Trim.execute(plain, state(img))
    assert {:ok, %State{image: equal_out}} = Trim.execute(equal, state(img))
    assert Image.width(equal_out) > Image.width(plain_out)
  end

  test "equal_ver symmetrizes to the smaller vertical margin" do
    img = bordered(40, 40, [0, 0, 0], [255, 255, 255], 4, 4, 32, 20)
    plain = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    equal = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: true}
    assert {:ok, %State{image: plain_out}} = Trim.execute(plain, state(img))
    assert {:ok, %State{image: equal_out}} = Trim.execute(equal, state(img))
    assert Image.height(equal_out) > Image.height(plain_out)
  end

  test "alpha source detects against a magenta flatten (border distinct from magenta)" do
    transparent = [0, 0, 0, 0]
    green = [10, 200, 10, 255]

    {:ok, canvas} =
      VixImage.build_image(40, 40, transparent, interpretation: :VIPS_INTERPRETATION_sRGB)

    {:ok, center} =
      VixImage.build_image(16, 16, green, interpretation: :VIPS_INTERPRETATION_sRGB)

    assert Image.has_alpha?(canvas)
    {:ok, composed} = Operation.insert(canvas, center, 12, 12)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(composed))
    assert Image.width(out) == 16
    assert Image.height(out) == 16
  end

  test "a find_trim failure (sub-window image) propagates as an error, not a no-op" do
    {:ok, tiny} = Operation.black(1, 1, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: false, equal_ver: false}
    assert {:error, {Trim, _}} = Trim.execute(op, state(tiny))
  end

  test "uniform + equal_hor only stays a no-op (vertical axis still 0)" do
    {:ok, img} = Operation.black(20, 20, bands: 3)
    op = %Trim{threshold: 10.0, background: :auto, equal_hor: true, equal_ver: false}
    assert {:ok, %State{image: out}} = Trim.execute(op, state(img))
    assert Image.width(out) == 20 and Image.height(out) == 20
  end
end
