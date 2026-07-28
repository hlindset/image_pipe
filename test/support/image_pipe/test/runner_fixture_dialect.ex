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
  alias ImagePipe.Dialect.RenderTerminal
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
  # the runner fetches with Keyword.fetch!, along with :allow_debug_headers
  # (validate_known_opts! merges the validated subset back).
  #
  # `:http_cache` is this fixture's own key, not a shared one, so it is split
  # out, validated here, and merged back — the same shape a real dialect's
  # config module uses for its dialect-specific options.
  def validate_config!(opts) do
    {http_cache, shared} = Keyword.pop(opts, :http_cache)

    case http_cache do
      nil -> SharedConfig.validate_runtime!(shared)
      [mode: mode] when mode in [:enabled, :disabled] -> validate_shared(shared, http_cache)
      other -> raise ArgumentError, "invalid :http_cache option: #{inspect(other)}"
    end
  end

  defp validate_shared(shared, http_cache),
    do: Keyword.put(SharedConfig.validate_runtime!(shared), :http_cache, http_cache)

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
          debug?: params["debug"] == "1",
          render: parse_render(params["render"]),
          http_cache: parse_http_cache(params["http_cache"])
        }

        {{:ok, request}, %{result: :ok}}
    end
  end

  def parse(%Plug.Conn{}, _config),
    do: {{:error, :not_found}, %{result: :error, error: :not_found}}

  defp parse_format("webp"), do: :webp
  defp parse_format("jpeg"), do: :jpeg
  defp parse_format("bmp"), do: :bmp
  defp parse_format("auto"), do: :auto
  defp parse_format(_), do: :jpeg

  defp parse_http_cache("generated"), do: :generated
  defp parse_http_cache(_), do: :dialect_owned

  defp parse_render("text"), do: :text
  defp parse_render("uncached"), do: :uncached
  defp parse_render(_), do: nil

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %{render: :text} = request, config) do
    negotiation = Negotiation.terminal(:fixture_text)

    {:ok,
     %Resolved{
       request: request,
       source: %Path{segments: request.segments},
       negotiation: {:ok, negotiation, material(request, negotiation, conn, config)},
       response_meta: %PlanResponse{},
       operations: [],
       auto_rotate?: true,
       debug?: request.debug?,
       http_cache: request.http_cache,
       terminal: {:render, render_terminal()}
     }}
  end

  def prepare(%Plug.Conn{} = conn, %{render: :uncached} = request, config) do
    negotiation = Negotiation.terminal(:fixture_uncached)

    {:ok,
     %Resolved{
       request: request,
       source: %Path{segments: request.segments},
       negotiation: {:ok, negotiation, material(request, negotiation, conn, config)},
       response_meta: %PlanResponse{},
       operations: [],
       auto_rotate?: true,
       debug?: request.debug?,
       http_cache: request.http_cache,
       terminal: {:render, uncached_render_terminal()}
     }}
  end

  def prepare(%Plug.Conn{} = conn, request, config) do
    plan_output =
      case request.format do
        :auto -> %Output{mode: :automatic, quality: :default}
        format -> %Output{mode: {:explicit, format}, quality: :default}
      end

    # A thunk, not an eager tuple: pins that the runner defers negotiation
    # until after ImagePipe.Source.resolve/3 succeeds (test process is the
    # calling process throughout, since prepare/3 and negotiation both run
    # synchronously before any streaming handoff).
    test_pid = self()

    negotiation = fn ->
      send(test_pid, :negotiation_invoked)

      case Negotiation.negotiate(conn, plan_output, config) do
        {:ok, negotiation} -> {:ok, negotiation, material(request, negotiation, conn, config)}
        {:error, _reason} = error -> error
      end
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
       http_cache: request.http_cache,
       terminal: :image
     }}
  end

  defp render_terminal do
    %RenderTerminal{
      fun: fn _resolved_source, _config -> {:ok, "text/plain; charset=utf-8", "fixture-body"} end
    }
  end

  defp uncached_render_terminal do
    %RenderTerminal{
      cache: :none,
      offers: [{"application/ld+json", ["application/ld+json"]}],
      fun: fn _resolved_source, _config -> {:ok, "application/json", ~s({"ok":true})} end
    }
  end

  # `storage_inputs` rides the mount config the way a real dialect's does, so a
  # runner-level test can mount a header partition and watch it reach both the
  # cache key and the response's Vary.
  defp material(request, negotiation, conn, config) do
    {storage_only, storage_vary} =
      Representation.storage_inputs(conn, Keyword.get(config, :storage_inputs, []))

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
