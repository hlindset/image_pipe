defmodule ImagePipe.Test.GuidedIIIFParser do
  @moduledoc false

  @behaviour ImagePipe.Parser

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Parser.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Pipeline

  @impl ImagePipe.Parser
  def validate_options!(opts), do: IIIF.validate_options!(opts)

  @impl ImagePipe.Parser
  def parse(conn, opts) do
    case IIIF.parse(conn, opts) do
      {:ok, %Plan{} = plan} -> {:ok, rewrite_guide(plan, selected_guide(conn))}
      result -> result
    end
  end

  @impl ImagePipe.Parser
  def handle_error(conn, error), do: IIIF.handle_error(conn, error)

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
