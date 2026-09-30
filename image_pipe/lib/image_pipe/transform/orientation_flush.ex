defmodule ImagePipe.Transform.OrientationFlush do
  @moduledoc false
  # Applies pending EXIF orientation, user rotation, then user flips; copies the
  # result to memory and clears pending orientation. Image.autorotate reads the
  # live EXIF tag, so call it only when auto_rotate? is true to respect ar:0.

  alias ImagePipe.Transform.{PendingOrientation, State}
  alias Vix.Vips.Image, as: VipsImage

  @spec flush(State.t()) :: {:ok, State.t()} | {:error, term()}
  def flush(%State{pending_orientation: %PendingOrientation{} = po} = state) do
    with {:ok, image} <- prepare_random_access(state.image, po),
         {:ok, image} <- apply_orientation(image, po),
         {:ok, image} <- VipsImage.copy_memory(image) do
      {:ok,
       %State{
         state
         | image: image,
           materialized?: true,
           pending_orientation: nil,
           buffer_before_resize?: false
       }}
    end
  end

  # Rotations by 90/180/270 degrees and vertical flips read rows out of order.
  # Copy the unrotated source to RAM first: copying only after orientation can
  # fail on sequential inputs too large for libvips to buffer silently.
  #
  # EXIF and user rotations execute as separate operations, so each must be safe
  # even when their net angle is zero. Materialize for EXIF orientations 3–8,
  # any nonzero user rotation, or a vertical flip. Identity and horizontal-only
  # mirrors preserve row order and skip this preliminary copy.
  defp prepare_random_access(image, %PendingOrientation{
         exif_angle: 0,
         user_angle: 0,
         user_flip_y: false
       }),
       do: {:ok, image}

  defp prepare_random_access(image, %PendingOrientation{}), do: VipsImage.copy_memory(image)

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

  # PendingOrientation carries only right-angle rotations. Image.rotate/3 uses
  # lossless vips_rot for these, avoiding affine resampling's 1px background seam.
  # Dialyzer can't see through Vix's generated Operation typings (rotate).
  @dialyzer {:no_fail_call, maybe_rotate: 2}
  defp maybe_rotate(image, 0), do: {:ok, image}
  defp maybe_rotate(image, angle) when angle in [90, 180, 270], do: Image.rotate(image, angle)

  defp maybe_flip(image, _axis, false), do: {:ok, image}
  defp maybe_flip(image, axis, true), do: Image.flip(image, axis)
end
