defmodule ImagePipe.Output.ColorProfile do
  @moduledoc false
  # Resolves a built-in target atom to its shipped CC0 .icc profile path.
  # Filenames are hardcoded per clause (never interpolated from the atom) so there
  # is no string-building seam for user input to slot into if a future custom-dir
  # slice is added. Request parsers emit exactly these three atoms; an unknown
  # atom is a programmer error and raises.

  # Compile-time presence guard only (build tree). Runtime resolution uses
  # :code.priv_dir/1 in path!/1 so the released artifact path is correct.
  @source_dir Path.expand(Path.join([__DIR__, "..", "..", "..", "priv", "icc"]))

  for name <- ["sRGB.icc", "DisplayP3.icc", "AdobeRGB.icc"] do
    path = Path.join(@source_dir, name)
    @external_resource path

    unless File.exists?(path) do
      raise "missing shipped ICC profile: #{path} (see priv/icc/PROVENANCE.md)"
    end
  end

  @spec path!(:srgb | :display_p3 | :adobe_rgb) :: String.t()
  def path!(:srgb), do: icc_path("sRGB.icc")
  def path!(:display_p3), do: icc_path("DisplayP3.icc")
  def path!(:adobe_rgb), do: icc_path("AdobeRGB.icc")

  # icc_path/1 only ever receives the three literals above — never user input.
  defp icc_path(name), do: Path.join([:code.priv_dir(:image_pipe), "icc", name])
end
