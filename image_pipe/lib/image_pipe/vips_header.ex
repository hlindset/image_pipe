defmodule ImagePipe.VipsHeader do
  # Edits image metadata without copying pixels.
  #
  # `Vix.Vips.Image.mutate/2` copies the image to memory before every edit,
  # which renders a lazy image in full: an extra frame and 15-40 ms on an
  # 18.7 MP image, for a header change. A copy made with `vips_copy` has its
  # own header and passes pixels through lazily, so this edits that copy with
  # the NIFs `Vix.Vips.MutableImage` calls. No pixels are read, so a corrupt
  # streamed source can't fail here.
  #
  # Vix builds every operation through the libvips operation cache, which
  # returns the same output image, header included, to identical calls. The
  # lazy copy is safe only while that cache is off, as `image_pipe_server`
  # and the tests set it. With the cache on, the image is buffered on the
  # caller's stack and edited through `mutate`, as before.
  #
  # Workaround for Vix 157bcf7: `MutableImage` copies pixels even for header
  # edits, and Vix has no public way to edit an uncached copy. Remove the
  # lazy path's cache gate and the `Vix.Nif` calls once Vix can
  # (image_plug-bvrn).
  @moduledoc false

  use Boundary, top_level?: true, deps: [], exports: []

  alias Vix.Vips.Image, as: VixImage
  alias Vix.Vips.MutableImage
  alias Vix.Vips.Operation

  @type edit :: {:remove, String.t()} | {:set, String.t(), atom(), term()}

  @doc """
  Returns `image` with `edits` applied to a copy of its header, in order.
  Removing an absent field does nothing. A failure to buffer the image
  (only with the operation cache on) returns `{:error, {:decode, reason}}`.
  """
  @spec edit(VixImage.t(), [edit()]) :: {:ok, VixImage.t()} | {:error, {:decode, term()}}
  def edit(%VixImage{} = image, []), do: {:ok, image}

  def edit(%VixImage{} = image, edits) do
    if Vix.Vips.cache_get_max() == 0,
      do: lazy_edit(image, edits),
      else: buffered_edit(image, edits)
  end

  # Dialyzer can't see through Vix's generated Operation typings (copy).
  @dialyzer {:no_fail_call, lazy_edit: 2}
  defp lazy_edit(image, edits) do
    {:ok, copy} = Operation.copy(image)
    Enum.each(edits, &apply_nif(copy, &1))
    {:ok, copy}
  end

  defp apply_nif(copy, {:remove, name}), do: Vix.Nif.nif_image_remove_metadata(copy.ref, name)

  defp apply_nif(copy, {:set, name, type, value}) do
    type = to_string(type)

    :ok =
      Vix.Nif.nif_image_set_metadata(copy.ref, name, type, Vix.Type.to_nif_term(type, value, nil))
  end

  # Buffered here so a corrupt source fails as a decode error instead of
  # crashing the process `mutate` links.
  defp buffered_edit(image, edits) do
    case VixImage.copy_memory(image) do
      {:ok, buffered} -> VixImage.mutate(buffered, &apply_mutable(&1, edits))
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  defp apply_mutable(mut, edits) do
    Enum.each(edits, fn
      {:remove, name} -> MutableImage.remove(mut, name)
      {:set, name, type, value} -> MutableImage.set(mut, name, type, value)
    end)
  end
end
