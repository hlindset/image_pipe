defmodule ImagePipe.SVG.Native do
  @moduledoc false

  version = Mix.Project.config()[:version]

  use RustlerPrecompiled,
    otp_app: :image_pipe_svg,
    crate: "image_pipe_svg_nif",
    base_url:
      "https://github.com/hlindset/image_pipe/releases/download/image_pipe_svg-v#{version}",
    version: version,
    nif_versions: ["2.15", "2.16", "2.17"],
    targets: ~w(
      aarch64-apple-darwin
      x86_64-apple-darwin
      x86_64-unknown-linux-gnu
      aarch64-unknown-linux-gnu
      x86_64-unknown-linux-musl
      aarch64-unknown-linux-musl
      x86_64-pc-windows-msvc
    )

  def versions, do: :erlang.nif_error(:nif_not_loaded)
  def load_fonts(_files, _fallback), do: :erlang.nif_error(:nif_not_loaded)

  def parse(_data, _fonts, _limits),
    do: :erlang.nif_error(:nif_not_loaded)

  def cost(_document, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
  def render(_document, _width, _height), do: :erlang.nif_error(:nif_not_loaded)
end
