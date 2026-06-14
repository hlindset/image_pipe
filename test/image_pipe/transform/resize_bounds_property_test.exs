defmodule ImagePipe.Transform.ResizeBoundsPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Transform.Operation.Resize

  property "maxArea is never exceeded for any source/area/^-or-not" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              area <- integer(10_000..40_000_000),
              enlarge <- boolean() do
      op = %Resize{mode: :fit, width: :auto, height: :auto, enlarge: enlarge, max_area: area}
      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width * r.intermediate_height <= area
    end
  end

  property "configured axis ceilings are never exceeded by the resolved result" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              max_w <- integer(16..4000),
              max_h <- integer(16..4000),
              enlarge <- boolean() do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: enlarge,
        max_width: max_w,
        max_height: max_h
      }

      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width <= max_w
      assert r.intermediate_height <= max_h
    end
  end

  # The IIIF path sets all three bounds at once (max_height inferred + max_area).
  # This is the case the single-bound properties above miss; it exercises the
  # floor-when-area-bounded rule.
  property "all three bounds combined never exceed any ceiling" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              max_w <- integer(64..4000),
              max_h <- integer(64..4000),
              max_a <- integer(10_000..40_000_000),
              enlarge <- boolean() do
      op = %Resize{
        mode: :fit,
        width: :auto,
        height: :auto,
        enlarge: enlarge,
        max_width: max_w,
        max_height: max_h,
        max_area: max_a
      }

      r = Resize.resolve_dimensions(op, source_width: src_w, source_height: src_h)
      assert r.intermediate_width <= max_w
      assert r.intermediate_height <= max_h
      assert r.intermediate_width * r.intermediate_height <= max_a
    end
  end

  # all-nil is a genuine no-op: the bounded-but-unset op resolves identically to
  # the same op with the field-free struct default (no rounding perturbation).
  property "all-nil bounds resolve identically to the default struct" do
    check all src_w <- integer(64..8000),
              src_h <- integer(64..8000),
              w <- integer(1..8000) do
      base = %Resize{mode: :fit, width: {:pixels, w}, height: :auto, enlarge: false}
      explicit_nil = %Resize{base | max_width: nil, max_height: nil, max_area: nil}

      r_base = Resize.resolve_dimensions(base, source_width: src_w, source_height: src_h)
      r_nil = Resize.resolve_dimensions(explicit_nil, source_width: src_w, source_height: src_h)

      assert r_base.intermediate_width == r_nil.intermediate_width
      assert r_base.intermediate_height == r_nil.intermediate_height
    end
  end
end
