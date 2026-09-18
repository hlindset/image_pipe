defmodule ImagePipe.Transform.PendingOrientation do
  @moduledoc false
  # Carries deferred EXIF orientation, user rotation, and user flips on State.
  # OrientationFlush applies them in that order. EXIF tags map to a rotation
  # followed by a horizontal mirror, matching imgproxy's angleFlip.

  defstruct auto_rotate?: false,
            exif_angle: 0,
            exif_flip_x: false,
            user_angle: 0,
            user_flip_x: false,
            user_flip_y: false

  @type t :: %__MODULE__{
          auto_rotate?: boolean(),
          exif_angle: 0 | 90 | 180 | 270,
          exif_flip_x: boolean(),
          user_angle: 0 | 90 | 180 | 270,
          user_flip_x: boolean(),
          user_flip_y: boolean()
        }

  @spec from_exif(1..8, boolean()) :: t()
  def from_exif(_orientation, false), do: %__MODULE__{auto_rotate?: false}

  def from_exif(orientation, true) do
    {angle, flip_x} = exif_angle_flip(orientation)
    %__MODULE__{auto_rotate?: true, exif_angle: angle, exif_flip_x: flip_x}
  end

  defp exif_angle_flip(1), do: {0, false}
  defp exif_angle_flip(2), do: {0, true}
  defp exif_angle_flip(3), do: {180, false}
  defp exif_angle_flip(4), do: {180, true}
  defp exif_angle_flip(5), do: {90, true}
  defp exif_angle_flip(6), do: {90, false}
  defp exif_angle_flip(7), do: {270, true}
  defp exif_angle_flip(8), do: {270, false}
  defp exif_angle_flip(_), do: {0, false}

  @spec fold_rotate(t(), 0 | 90 | 180 | 270) :: t()
  def fold_rotate(%__MODULE__{} = po, angle) when angle in [90, 270] do
    # The flush stores rotation before flips. A later quarter turn rotates
    # the existing flip axes too, preserving the requested composition.
    %__MODULE__{
      po
      | user_angle: rem(po.user_angle + angle, 360),
        user_flip_x: po.user_flip_y,
        user_flip_y: po.user_flip_x
    }
  end

  def fold_rotate(%__MODULE__{user_angle: a} = po, angle),
    do: %__MODULE__{po | user_angle: rem(a + angle, 360)}

  @spec fold_flip(t(), :horizontal | :vertical | :both) :: t()
  def fold_flip(%__MODULE__{} = po, :horizontal),
    do: %__MODULE__{po | user_flip_x: not po.user_flip_x}

  def fold_flip(%__MODULE__{} = po, :vertical),
    do: %__MODULE__{po | user_flip_y: not po.user_flip_y}

  def fold_flip(%__MODULE__{} = po, :both),
    do: %__MODULE__{po | user_flip_x: not po.user_flip_x, user_flip_y: not po.user_flip_y}

  @spec quarter_turn?(t()) :: boolean()
  def quarter_turn?(%__MODULE__{exif_angle: ea, user_angle: ua}), do: rem(ea + ua, 180) == 90

  @doc "True when there is no pixel work to flush (identity orientation)."
  @spec identity?(t()) :: boolean()
  def identity?(%__MODULE__{
        exif_angle: 0,
        exif_flip_x: false,
        user_angle: 0,
        user_flip_x: false,
        user_flip_y: false
      }),
      do: true

  def identity?(%__MODULE__{}), do: false

  @doc """
  Returns display dimensions for the given storage dimensions.

  Swaps axes for a pending quarter turn; `nil` leaves dimensions unchanged.
  """
  @spec display_dims({pos_integer(), pos_integer()}, t() | nil) ::
          {pos_integer(), pos_integer()}
  def display_dims(dims, nil), do: dims

  def display_dims({w, h} = dims, %__MODULE__{} = po),
    do: if(quarter_turn?(po), do: {h, w}, else: dims)
end
