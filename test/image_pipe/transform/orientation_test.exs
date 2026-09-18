defmodule ImagePipe.Transform.OrientationTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Orientation, as: O

  describe "compensate_gravity/4 — directional remap (offsets 0)" do
    test "anchor types remap under 90/180/270" do
      assert O.compensate_gravity({:anchor, :center, :top}, 90, false, false) ==
               {:anchor, :left, :center}

      assert O.compensate_gravity({:anchor, :center, :top}, 180, false, false) ==
               {:anchor, :center, :bottom}

      assert O.compensate_gravity({:anchor, :center, :top}, 270, false, false) ==
               {:anchor, :right, :center}
    end

    test "corner antipode at 180" do
      assert O.compensate_gravity({:anchor, :left, :top}, 180, false, false) ==
               {:anchor, :right, :bottom}
    end

    test "flipX swaps left/right; flipY swaps top/bottom" do
      assert O.compensate_gravity({:anchor, :left, :top}, 0, true, false) ==
               {:anchor, :right, :top}

      assert O.compensate_gravity({:anchor, :left, :top}, 0, false, true) ==
               {:anchor, :left, :bottom}
    end
  end

  describe "compensate_gravity/4 — focus point" do
    test "90° maps (x,y) -> (y, 1-x)" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 90, false, false) == {:fp, 0.10, 0.75}
    end

    test "flipX maps x -> 1-x" do
      assert O.compensate_gravity({:fp, 0.25, 0.10}, 0, true, false) == {:fp, 0.75, 0.10}
    end
  end

  describe "compensate_gravity/4 — never-remapped types" do
    test "smart/detect pass through unchanged" do
      assert O.compensate_gravity(:smart, 90, false, false) == :smart

      assert O.compensate_gravity({:smart, :face_assist}, 90, false, false) ==
               {:smart, :face_assist}
    end
  end

  describe "compensate_gravity_for/2 — offsets (port of gravity.go:96-153)" do
    alias ImagePipe.Transform.PendingOrientation, as: PO

    # For FP, the tuple coords flip via the `1 - fx` focus-coord rule, but the
    # SEPARATE crop offset is a plain displacement and negates like a vector (it
    # is NOT a focus coord; imgproxy's FP path has no separate offset — see
    # Orientation moduledoc). The `1 - x` fraction rule must not touch it.
    test "flipX negates X for center/N/S and for the FP offset; type remaps too" do
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_flip_x: true}) ==
               {{:anchor, :center, :top}, -5.0, 3.0}

      assert O.compensate_gravity_for({{:fp, 0.25, 0.1}, 0.2, 0.3}, %PO{user_flip_x: true}) ==
               {{:fp, 0.75, 0.1}, -0.2, 0.3}
    end

    test "flipY negates Y for center/E/W, 1-y for FP" do
      assert O.compensate_gravity_for({{:anchor, :left, :center}, 2.0, 4.0}, %PO{
               user_flip_y: true
             }) ==
               {{:anchor, :left, :center}, 2.0, -4.0}
    end

    # ---- ROTATE offset rows, derived from local/imgproxy-master/processing/gravity.go:117-153.
    # The offset switch keys on the POST-remap GravityType (gravity.go remaps g.Type at
    # lines 119-121 BEFORE the offset switch at 123-153 reads g.Type).
    #
    # Anchor mapping: {:anchor,:center,:top}=North, {:anchor,:center,:bottom}=South,
    # {:anchor,:left,:center}=West, {:anchor,:right,:center}=East,
    # {:anchor,:center,:center}=Center.

    test "rotate 90 — anchor types (offset switch keys on post-remap type)" do
      # Center: no rotation remap; post-remap Center -> X,Y = Y,-X (gravity.go:126-127)
      assert O.compensate_gravity_for(
               {{:anchor, :center, :center}, 5.0, 3.0},
               %PO{user_angle: 90}
             ) == {{:anchor, :center, :center}, 3.0, -5.0}

      # North -> West (gravity.go:10); post-remap West in {Center,East,West} -> Y,-X
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :left, :center}, 3.0, -5.0}

      # South -> East (gravity.go:12); post-remap East -> Y,-X
      assert O.compensate_gravity_for({{:anchor, :center, :bottom}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :right, :center}, 3.0, -5.0}

      # East -> North (gravity.go:11); post-remap North hits default -> X,Y = Y,X (gravity.go:131)
      assert O.compensate_gravity_for({{:anchor, :right, :center}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :center, :top}, 3.0, 5.0}

      # West -> South (gravity.go:13); post-remap South hits default -> Y,X
      assert O.compensate_gravity_for({{:anchor, :left, :center}, 5.0, 3.0}, %PO{user_angle: 90}) ==
               {{:anchor, :center, :bottom}, 3.0, 5.0}
    end

    test "rotate 180 — anchor types (offset switch keys on post-remap type)" do
      # Center: no remap; post-remap Center -> -X,-Y (gravity.go:135-136)
      assert O.compensate_gravity_for(
               {{:anchor, :center, :center}, 5.0, 3.0},
               %PO{user_angle: 180}
             ) == {{:anchor, :center, :center}, -5.0, -3.0}

      # North -> South (gravity.go:20); post-remap South in {North,South} -> X = -X (gravity.go:137-138)
      assert O.compensate_gravity_for({{:anchor, :center, :top}, 5.0, 3.0}, %PO{user_angle: 180}) ==
               {{:anchor, :center, :bottom}, -5.0, 3.0}

      # East -> West (gravity.go:21); post-remap West in {East,West} -> Y = -Y (gravity.go:139-140)
      assert O.compensate_gravity_for({{:anchor, :right, :center}, 5.0, 3.0}, %PO{user_angle: 180}) ==
               {{:anchor, :left, :center}, 5.0, -3.0}
    end

    # The FP *tuple* coords rotate via the focus-coord rules (rotate_fp): 90→{y,1-x},
    # 180→{1-x,1-y}, 270→{1-y,x} — these mirror imgproxy's GravityFocusPoint X/Y
    # rotation (gravity.go:128-149). The SEPARATE crop offset is a plain
    # displacement with no imgproxy FP analog (calc_position.go uses only the focus
    # coords for GravityFocusPoint), so it rotates like the GravityCenter vector:
    # 90→{y,-x}, 180→{-x,-y}, 270→{-y,x}. Applying the `1 - x` fraction rule to it
    # injected a spurious 1px shift at 90/270 (#146 Bug 3).
    test "rotate 90/180/270 — focus point (tuple coords rotate as coords; offset as a vector)" do
      # 90: tuple FP {y,1-x}; offset vector {y,-x}
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 90}) ==
               {{:fp, 0.10, 0.75}, 0.3, -0.2}

      # 180: tuple FP {1-x,1-y}; offset vector {-x,-y}
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 180}) ==
               {{:fp, 0.75, 0.90}, -0.2, -0.3}

      # 270: tuple FP {1-y,x}; offset vector {-y,x}
      assert O.compensate_gravity_for({{:fp, 0.25, 0.10}, 0.2, 0.3}, %PO{user_angle: 270}) ==
               {{:fp, 0.90, 0.25}, -0.3, 0.2}
    end
  end

  describe "swap_dims?/1 and swap_resize/1" do
    test "swap on quarter-turn only" do
      assert O.swap_dims?(90) and O.swap_dims?(270)
      refute O.swap_dims?(0) or O.swap_dims?(180)
    end

    test "swap_resize swaps resolved pixel dimensions" do
      resize = %ImagePipe.Transform.Operation.Resize{
        width: 100,
        height: 50
      }

      swapped = O.swap_resize(resize)
      assert swapped.width == 50 and swapped.height == 100
    end
  end

  describe "center_discard_sides/1 — center-crop odd-discard side under orientation (#146 Bug 2)" do
    alias ImagePipe.Transform.PendingOrientation, as: PO

    # A storage axis needs its center-discard rounding flipped to :far exactly when
    # its near (origin) edge maps to a far (right/bottom) display edge after the
    # flush. Mapping derived from Image.autorotate of a near-edge marker per EXIF
    # tag, and re-derived here from the pure forward transform.
    test "EXIF tags 1..8" do
      expected = %{
        1 => {:near, :near},
        2 => {:far, :near},
        3 => {:far, :far},
        4 => {:near, :far},
        5 => {:near, :near},
        6 => {:near, :far},
        7 => {:far, :far},
        8 => {:far, :near}
      }

      for {tag, sides} <- expected do
        assert O.center_discard_sides(PO.from_exif(tag, true)) == sides,
               "EXIF-#{tag} expected #{inspect(sides)}"
      end
    end

    test "identity and pure horizontal mirror keep :near" do
      assert O.center_discard_sides(%PO{}) == {:near, :near}
      assert O.center_discard_sides(%PO{user_flip_x: true}) == {:far, :near}
      assert O.center_discard_sides(%PO{user_flip_y: true}) == {:near, :far}
    end

    test "user 180 reverses both axes" do
      assert O.center_discard_sides(%PO{user_angle: 180}) == {:far, :far}
    end
  end
end
