defmodule ImagePipe.Transform.SourceGeometryTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry

  # Builds a geometry the way ImagePipe.Decode.with_image/4 does: display
  # dims computed once at construction time via PendingOrientation.display_dims/2
  # from whatever pending orientation the decode observed (here always seeded
  # with auto_rotate?: true, so quarter-turn orientations actually swap).
  defp geometry_for(orientation) do
    storage = {800, 600}
    pending = PendingOrientation.from_exif(orientation, true)
    display = PendingOrientation.display_dims(storage, pending)

    %SourceGeometry{
      storage_dimensions: storage,
      display_dimensions: display,
      pending_orientation: pending,
      source_format: :jpeg
    }
  end

  describe "planning_frame/2" do
    test "orientation 1 (identity): display dims equal storage dims" do
      geometry = geometry_for(1)

      assert geometry.display_dimensions == {800, 600}
      assert SourceGeometry.planning_frame(geometry, true) == {800, 600}
      assert SourceGeometry.planning_frame(geometry, false) == {800, 600}
    end

    test "orientation 6 (quarter turn): auto_rotate? true returns swapped display dims" do
      geometry = geometry_for(6)

      assert geometry.display_dimensions == {600, 800}
      assert SourceGeometry.planning_frame(geometry, true) == {600, 800}
    end

    test "orientation 6 (quarter turn): auto_rotate? false returns storage dims" do
      geometry = geometry_for(6)

      assert SourceGeometry.planning_frame(geometry, false) == {800, 600}
    end

    test "orientation 8 (quarter turn): auto_rotate? true returns swapped display dims" do
      geometry = geometry_for(8)

      assert geometry.display_dimensions == {600, 800}
      assert SourceGeometry.planning_frame(geometry, true) == {600, 800}
    end

    test "orientation 8 (quarter turn): auto_rotate? false returns storage dims" do
      geometry = geometry_for(8)

      assert SourceGeometry.planning_frame(geometry, false) == {800, 600}
    end
  end
end
