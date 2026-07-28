defmodule ImagePipe.RequestSafetyTest.InvalidPlanDialect do
  @moduledoc false
  # A declarative dialect whose plan carries an unusable output — a shape a host
  # `parse_plan/2` can emit, and which the tier must reject before it resolves a
  # source identity, reads the cache, or touches an origin.

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Dialect.SharedConfig

  @impl ImagePipe.Dialect
  def validate_config!(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {base, []} = Keyword.split(rest, Declarative.config_keys())

    Keyword.merge(SharedConfig.validate_runtime!(shared), Declarative.validate_config!(base))
  end

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(_conn, _config) do
    {:ok,
     %ImagePipe.Plan{
       source: %ImagePipe.Plan.Source.Path{segments: ["images", "cat.jpg"]},
       pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
       output: :invalid_output,
       response: %ImagePipe.Plan.Response{}
     }}
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: IIIF.render_error(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(reason), do: IIIF.classify_error(reason)
end
