defmodule ImagePipe.Test.RunnerFixtureDialect do
  @moduledoc false

  # The :boundary compiler runs in all envs; without a declaration this
  # module would fall into the ImagePipe root boundary and violate its deps.
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ]

  @behaviour ImagePipe.Dialect

  import Plug.Conn, only: [send_resp: 3, fetch_query_params: 1]

  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial
  alias ImagePipe.Transform.DecodePlanner

  @impl ImagePipe.Dialect
  # SharedConfig converts :sources/:cache into the shapes Source.resolve and
  # Cache expect (a raw keyword `sources:` fails with {:source,
  # :missing_adapter} — Source.fetch_adapter_config pattern-matches a map)
  # and supplies the max_result_*/max_body_bytes/max_input_pixels defaults
  # the runner fetches with Keyword.fetch!. Unknown keys such as the
  # fixture-only :allow_debug_headers pass through untouched
  # (validate_known_opts! merges the validated subset back).
  def validate_config!(opts), do: SharedConfig.validate_runtime!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{path_info: ["fix" | segments]} = conn, _config) do
    conn = fetch_query_params(conn)

    case conn.query_params do
      %{"boom" => "parse"} ->
        {{:error, :fixture_parse_reject}, %{result: :error, error: :fixture_parse_reject}}

      params ->
        request = %{
          segments: segments,
          format: parse_format(params["format"]),
          debug?: params["debug"] == "1"
        }

        {{:ok, request}, %{result: :ok}}
    end
  end

  def parse(%Plug.Conn{}, _config),
    do: {{:error, :not_found}, %{result: :error, error: :not_found}}

  defp parse_format("webp"), do: :webp
  defp parse_format("jpeg"), do: :jpeg
  defp parse_format("bmp"), do: :bmp
  defp parse_format(_), do: :jpeg

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, request, config) do
    plan_output = %Output{mode: {:explicit, request.format}, quality: :default}

    negotiation =
      case Negotiation.negotiate(conn, plan_output, config) do
        {:ok, negotiation} -> {:ok, negotiation, material(request, negotiation, conn, config)}
        {:error, _reason} = error -> error
      end

    {:ok,
     %Resolved{
       request: request,
       source: %Path{segments: request.segments},
       negotiation: negotiation,
       response_meta: %PlanResponse{},
       operations: [],
       auto_rotate?: true,
       debug?: request.debug?,
       terminal: :image
     }}
  end

  defp material(request, negotiation, conn, _config) do
    {storage_only, storage_vary} = Representation.storage_inputs(conn, [])

    %IdentityMaterial{
      dialect_behavior: {__MODULE__, 1},
      representation: [
        segments: request.segments,
        selection: negotiation.selected,
        output_policy: negotiation.policy_material
      ],
      storage_only: storage_only,
      vary_header_names: if(negotiation.vary?, do: storage_vary ++ ["Accept"], else: storage_vary)
    }
  end

  @impl ImagePipe.Dialect
  def decode_request(_request, _geometry), do: %DecodePlanner.Request{}

  @impl ImagePipe.Dialect
  def execute(state, _geometry, _request, _opts), do: {:ok, state}

  @impl ImagePipe.Dialect
  def render_error(conn, :fixture_parse_reject, _config),
    do: send_resp(conn, 422, "fixture parse reject")

  def render_error(conn, :not_found, _config), do: send_resp(conn, 404, "not found")
  def render_error(conn, {:source, _}, _config), do: send_resp(conn, 404, "source error")

  def render_error(conn, {:unsupported_output_format, _}, _config),
    do: send_resp(conn, 415, "unsupported output")

  def render_error(conn, _reason, _config), do: send_resp(conn, 500, "error")

  @impl ImagePipe.Dialect
  def classify_error(:fixture_parse_reject), do: :parser_error
  def classify_error(reason), do: ImagePipe.Telemetry.request_result({:error, reason})
end
