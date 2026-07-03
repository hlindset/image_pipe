defmodule ImagePipe.Transform.PendingOrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.PendingOrientation, as: PO

  describe "from_exif/2" do
    test "maps EXIF orientation 1..8 to angle + horizontal mirror" do
      assert PO.from_exif(1, true) == %PO{auto_rotate?: true, exif_angle: 0, exif_flip_x: false}
      assert PO.from_exif(2, true) == %PO{auto_rotate?: true, exif_angle: 0, exif_flip_x: true}
      assert PO.from_exif(3, true) == %PO{auto_rotate?: true, exif_angle: 180, exif_flip_x: false}
      assert PO.from_exif(4, true) == %PO{auto_rotate?: true, exif_angle: 180, exif_flip_x: true}
      assert PO.from_exif(5, true) == %PO{auto_rotate?: true, exif_angle: 90, exif_flip_x: true}
      assert PO.from_exif(6, true) == %PO{auto_rotate?: true, exif_angle: 90, exif_flip_x: false}
      assert PO.from_exif(7, true) == %PO{auto_rotate?: true, exif_angle: 270, exif_flip_x: true}
      assert PO.from_exif(8, true) == %PO{auto_rotate?: true, exif_angle: 270, exif_flip_x: false}
    end

    test "auto_rotate? false yields no EXIF contribution regardless of tag" do
      assert PO.from_exif(6, false) == %PO{auto_rotate?: false, exif_angle: 0, exif_flip_x: false}
    end
  end

  describe "fold_rotate/2 and fold_flip/2" do
    test "accumulates user rotate additively mod 360" do
      po = %PO{user_angle: 90} |> PO.fold_rotate(270)
      assert po.user_angle == 0
    end

    test "folds horizontal/vertical/both flips" do
      assert PO.fold_flip(%PO{}, :horizontal).user_flip_x == true
      assert PO.fold_flip(%PO{}, :vertical).user_flip_y == true
      both = PO.fold_flip(%PO{}, :both)
      assert both.user_flip_x == true and both.user_flip_y == true
    end
  end

  describe "quarter_turn?/1" do
    test "true iff combined exif+user angle is 90 or 270 mod 180" do
      assert PO.quarter_turn?(%PO{exif_angle: 90, user_angle: 0}) == true
      assert PO.quarter_turn?(%PO{exif_angle: 90, user_angle: 90}) == false
      assert PO.quarter_turn?(%PO{exif_angle: 0, user_angle: 270}) == true
      assert PO.quarter_turn?(%PO{exif_angle: 180, user_angle: 0}) == false
    end
  end

  describe "display_dims/2" do
    test "nil pending and non-quarter turns keep the axes" do
      assert PO.display_dims({80, 40}, nil) == {80, 40}

      half_turn = %PO{auto_rotate?: true, exif_angle: 180}
      assert PO.display_dims({80, 40}, half_turn) == {80, 40}
    end

    test "a pending quarter turn swaps the axes" do
      quarter = %PO{auto_rotate?: true, exif_angle: 90}
      assert PO.display_dims({40, 80}, quarter) == {80, 40}
    end
  end
end
