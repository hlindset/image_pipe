defmodule ImagePipe.Test.ImgproxyDifferential.Harness do
  @moduledoc """
  Thin wrapper over `Differential.Harness` for the imgproxy suite. The conformance
  test, `mix imgproxy.gen_report`, and `mix imgproxy.diagnose` all render
  identically through this façade.
  """

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Harness, as: Shared
  alias ImagePipe.Test.ImgproxyDifferential.Constellations

  @base "test/support/image_pipe/test/imgproxy_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"

  @doc """
  `ImagePipe.Plug` opts wired to serve the committed sources locally. Build once and
  thread it through repeated `render/2` calls to avoid re-initializing per render.
  """
  def plug_opts, do: Shared.plug_opts(ImagePipe.Parser.Imgproxy, @sources_dir)

  @doc "Live ImagePipe render for a constellation → `{body_bytes, content_type}`."
  def render(constellation, plug_opts \\ plug_opts()),
    do: Shared.render(Constellations.imgproxy_path(constellation), plug_opts)

  @doc "Live ImagePipe render decoded to a `Vix.Vips.Image`."
  def render_image(constellation, plug_opts \\ plug_opts()),
    do: Shared.render_image(Constellations.imgproxy_path(constellation), plug_opts)

  @doc "Absolute path to a manifest entry's committed fixture PNG."
  def fixture_path(%{fixture_filename: filename}), do: Path.join(@fixtures_dir, filename)

  @doc "Open a manifest entry's committed fixture PNG to a `Vix.Vips.Image`."
  def fixture_image(entry),
    do: Image.open!(File.read!(fixture_path(entry)), access: :random, fail_on: :error)
end
