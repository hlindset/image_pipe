defmodule ImagePipe.Test.AutomaticIIIFDialect do
  @moduledoc false
  # IIIF with the output mode forced to :automatic, so the Accept-negotiation
  # suites keep a dialect that varies by Accept. The IIIF path grammar always
  # names a format, so real IIIF only ever emits `{:explicit, format}` — this
  # double is the only in-tree witness for automatic-output behavior on the
  # declarative tier (negotiation Vary and Accept-sensitive identity).

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: IIIF.validate_config!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(conn, config) do
    case IIIF.parse_plan(conn, config) do
      {:ok, %Plan{output: %Output{} = output} = plan} ->
        {:ok, %Plan{plan | output: %Output{output | mode: :automatic}}}

      result ->
        result
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: IIIF.render_error(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(reason), do: IIIF.classify_error(reason)
end
