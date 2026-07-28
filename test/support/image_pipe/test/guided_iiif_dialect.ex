defmodule ImagePipe.Test.GuidedIIIFDialect do
  @moduledoc false
  # IIIF with the leading crop's guide rewritten from a `?guide=` query param,
  # so the suites keep a dialect that can request focal and detector-backed
  # crops — shapes the IIIF grammar itself cannot spell.

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Pipeline

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: IIIF.validate_config!(opts)

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(conn, config) do
    case IIIF.parse_plan(conn, config) do
      {:ok, %Plan{} = plan} -> {:ok, rewrite_guide(plan, selected_guide(conn))}
      result -> result
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, reason, config), do: IIIF.render_error(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(reason), do: IIIF.classify_error(reason)

  defp selected_guide(conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Map.get(conn.query_params, "guide") do
      "focal" -> {:focal, {:ratio, 3, 10}, {:ratio, 7, 10}}
      "face_assist" -> {:smart, :face_assist}
      _other -> nil
    end
  end

  defp rewrite_guide(
         %Plan{
           pipelines: [
             %Pipeline{operations: [%CropGuided{} = crop | operations]} = pipeline | pipelines
           ]
         } = plan,
         guide
       )
       when not is_nil(guide) do
    pipeline = %Pipeline{pipeline | operations: [%CropGuided{crop | guide: guide} | operations]}
    %Plan{plan | pipelines: [pipeline | pipelines]}
  end

  defp rewrite_guide(%Plan{} = plan, _guide), do: plan
end
