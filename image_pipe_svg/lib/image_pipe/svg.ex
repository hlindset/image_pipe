defmodule ImagePipe.SVG do
  @moduledoc """
  SVG support for ImagePipe.

  `image_pipe` calls this package when it is installed. It has no API meant
  for direct use.
  """

  alias ImagePipe.SVG.Native

  @doc """
  Returns the versions of this package's NIF and the resvg it was built with.

  ImagePipe puts them in the cache key, since a new resvg can render the same
  SVG differently.
  """
  @spec versions() :: %{nif: String.t(), resvg: String.t()}
  def versions do
    {nif, resvg} = Native.versions()
    %{nif: nif, resvg: resvg}
  end
end
