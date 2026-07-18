defmodule ImagePipe.Test.TwicpicsDifferential.Harness do
  @moduledoc "Thin wrapper over `Differential.Harness` for the TwicPics suite."
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Harness, as: Shared
  alias ImagePipe.Test.TwicpicsDifferential.Constellations

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"

  def plug_opts, do: plug_opts(:dialect)

  def plug_opts(:framework), do: Shared.plug_opts(ImagePipe.Parser.TwicPics, @sources_dir)

  def plug_opts(:dialect),
    do: Shared.dialect_plug_opts(ImagePipe.Dialect.TwicPics, @sources_dir)

  def render(constellation, plug_opts \\ plug_opts()),
    do: Shared.render(Constellations.twicpics_path(constellation), plug_opts)

  def render_image(constellation, plug_opts \\ plug_opts()),
    do: Shared.render_image(Constellations.twicpics_path(constellation), plug_opts)

  def fixtures_dir, do: @fixtures_dir
  def sources_dir, do: @sources_dir
  def fixture_path(filename), do: Path.join(@fixtures_dir, filename)

  @doc "Open a manifest entry's committed fixture PNG to a `Vix.Vips.Image`."
  def fixture_image(%{fixture_filename: f}),
    do: Image.open!(File.read!(fixture_path(f)), access: :random, fail_on: :error)
end
