defmodule ImagePipe.Transform.MemoryCopy do
  # Copies an image to RAM for random access.
  #
  # A sequential loader marks its image `vips-sequential`, and `copy_memory`
  # keeps the mark. libvips reads a marked image strictly top to bottom, which
  # makes later resizes of the in-memory copy several times slower. The copy
  # can be read in any order, so the mark is removed.
  @moduledoc false

  alias Vix.Vips.Image, as: VipsImage
  alias Vix.Vips.MutableImage

  @sequential "vips-sequential"

  @spec copy(VipsImage.t()) :: {:ok, VipsImage.t()} | {:error, term()}
  def copy(image) do
    with {:ok, copy} <- VipsImage.copy_memory(image) do
      case VipsImage.header_value(copy, @sequential) do
        {:ok, _value} -> VipsImage.mutate(copy, &MutableImage.remove(&1, @sequential))
        {:error, _missing} -> {:ok, copy}
      end
    end
  end
end
