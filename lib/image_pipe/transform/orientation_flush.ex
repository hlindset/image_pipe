defmodule ImagePipe.Transform.OrientationFlush do
  @moduledoc false
  # Applies pending orientation pixels late (EXIF ∘ user rotate ∘ user flip),
  # then copy_memory, then clears pending. The single place orientation pixels are
  # written. EXIF is replayed via Image.autorotate ONLY when auto_rotate? is true:
  # autorotate reads the live EXIF tag, so calling it for an ar:0 source that still
  # carries a tag would wrongly apply suppressed EXIF rotation.

  alias ImagePipe.Transform.{Focus, PendingOrientation, State}
  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.Operation

  @spec flush(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush(%State{pending_orientation: nil} = state), do: materialize(state)

  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    pre = {Image.width(state.image), Image.height(state.image)}

    with {:ok, image} <- prepare_random_access(state.image, po),
         {:ok, image} <- apply_orientation(image, po),
         {:ok, image} <- VipsImage.copy_memory(image) do
      # The flush is itself a focus-transforming op: a carried focus rotates/
      # reflects with the pixels (storage -> display frame) on the pre-flush dims.
      state = Focus.reflect_rotate(state, po, pre)
      {:ok, %State{state | image: image, materialized?: true, pending_orientation: nil}}
    end
  end

  # A quarter-turn rotate (90°/270°) or a vertical flip reads its source out of
  # row order, which the lazy `access: :sequential` decode (DecodePlanner) cannot
  # satisfy: applying the orientation to a streamed source and then `copy_memory`
  # trips the sequential-access wall ("Failed to memory copy image") once the
  # image is large enough that libvips can't silently buffer it. So when the
  # pending orientation needs arbitrary pixel access, materialize the *un-rotated*
  # image to RAM first (mirroring the old eager AutoOrient), giving the rotate a
  # random-access source. A plain sequential read into RAM always succeeds; the
  # rotate then runs over the buffer and the trailing copy_memory holds.
  #
  # `apply_orientation` runs the EXIF autorotate (exif_angle rotation + an hflip
  # when exif_flip_x) and the user rotate as SEPARATE libvips ops. EACH stage that
  # rotates 90/180/270 — or vertically flips — reads its source out of row order
  # and independently needs a random-access source. The intermediate result of one
  # such stage is itself a lazy pipeline node over the sequential decode, so it is
  # not enough to look at the NET combined angle: when an EXIF quarter/half-turn
  # and a user rotate cancel (net 0 mod 360) the per-stage rotations still execute
  # and still trip the wall. The predicate must therefore fire whenever ANY
  # individual stage needs random access: the EXIF rotation (`exif_angle != 0`,
  # catching EXIF orientations 3-8), the user rotation (`user_angle != 0`), or a
  # vertical flip (`user_flip_y`).
  #
  # Identity and pure horizontal mirrors stay sequential-safe — they read rows in
  # order — so they skip the pre-copy and preserve the streaming fast path: EXIF
  # orientations 1/2 have `exif_angle == 0` (1 is identity, 2 is hflip) and a
  # user hflip alone leaves all three angle/flip-y fields zero. This mirrors #143's
  # classification (only EXIF orientations 1/2 stream; 3-8 materialize). A pre-copy
  # is pixel-identity, so an over-eager pre-copy would only cost perf; the per-stage
  # predicate is chosen to never UNDER-fire (no remaining holes) while still keeping
  # the streaming path for the genuinely row-ordered cases.
  defp prepare_random_access(image, %PendingOrientation{} = po) do
    if needs_random_access?(po) do
      VipsImage.copy_memory(image)
    else
      {:ok, image}
    end
  end

  defp needs_random_access?(%PendingOrientation{} = po) do
    po.exif_angle != 0 or po.user_angle != 0 or po.user_flip_y
  end

  defp materialize(%State{} = state) do
    case VipsImage.copy_memory(state.image) do
      {:ok, image} -> {:ok, %State{state | image: image, materialized?: true}}
      {:error, _} = error -> error
    end
  end

  defp apply_orientation(image, %PendingOrientation{} = po) do
    with {:ok, image} <- maybe_autorotate(image, po),
         {:ok, image} <- maybe_rotate(image, po.user_angle),
         {:ok, image} <- maybe_flip(image, :horizontal, po.user_flip_x) do
      maybe_flip(image, :vertical, po.user_flip_y)
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: true}) do
    case Image.autorotate(image) do
      {:ok, {image, _flags}} -> {:ok, image}
      {:error, _} = error -> error
    end
  end

  defp maybe_autorotate(image, %PendingOrientation{auto_rotate?: false}), do: {:ok, image}

  # The user rotate is always a right angle (PendingOrientation folds only
  # right-angle %Rotate{} into user_angle), so it must use libvips' exact
  # right-angle rotate `vips_rot` — the same primitive Image.autorotate runs for
  # EXIF, and the one imgproxy uses for orientation (vips.go `Rotate` →
  # `vips_rot_go`), so this is also the parity-correct choice.
  #
  # We call `Vix.Vips.Operation.rot/2` directly because the `image` library has
  # no public exact-rotate facade: `Image.rotate/2` is the *arbitrary-angle*
  # affine rotate (`vips_rotate`), and at a 90° multiple its affine maps the
  # content ~1px off the output canvas, leaving a 1px uncovered strip filled with
  # its `:background` colour (black by default) — the #211 seam. (libvips splits
  # `vips_rot` and `vips_rotate` deliberately; the seam is `vips_rotate` working
  # as designed, not a resample blend — a white background makes the strip white.)
  defp maybe_rotate(image, 0), do: {:ok, image}
  defp maybe_rotate(image, 90), do: Operation.rot(image, :VIPS_ANGLE_D90)
  defp maybe_rotate(image, 180), do: Operation.rot(image, :VIPS_ANGLE_D180)
  defp maybe_rotate(image, 270), do: Operation.rot(image, :VIPS_ANGLE_D270)

  defp maybe_flip(image, _axis, false), do: {:ok, image}
  defp maybe_flip(image, axis, true), do: Image.flip(image, axis)
end
