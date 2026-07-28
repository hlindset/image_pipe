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
  The dialect arm wired to serve the committed sources locally: an opaque
  `{ImagePipe.Plug, initialized_opts}` pair, mounted in dialect mode. Build
  once and thread it through repeated `render/2` calls to avoid
  re-initializing per render.

  Built locally rather than through `Shared.dialect_plug_opts/2` because that
  helper is also used by the TwicPics differential harness, which cannot yet
  mount through `ImagePipe.Plug` (its dialect ships in a later task). Once
  both dialects mount the same way, this local construction can fold back
  into the shared helper.
  """
  def plug_opts,
    do:
      {ImagePipe.Plug,
       ImagePipe.Plug.init(
         dialect: ImagePipe.Dialect.Imgproxy,
         sources: Shared.sources(@sources_dir)
       )}

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
