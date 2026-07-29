defmodule ImagePipe.Test.DeclarativeFixtureDialect do
  @moduledoc false
  # The smallest possible host dialect on the declarative tier: proof that a
  # third party can `use ImagePipe.Dialect.Declarative`, implement three
  # functions, and mount through `ImagePipe.Plug` with no core changes.

  use Boundary, top_level?: true, check: [out: false]
  use ImagePipe.Dialect.Declarative

  alias ImagePipe.Dialect.Declarative
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.SharedConfig
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @impl ImagePipe.Dialect
  def validate_config!(opts) do
    {shared, rest} = Keyword.split(opts, SharedConfig.keys())
    {base, []} = Keyword.split(rest, Declarative.config_keys())

    Keyword.merge(SharedConfig.validate_runtime!(shared), Declarative.validate_config!(base))
  end

  @impl ImagePipe.Dialect.Declarative
  def parse_plan(%Plug.Conn{} = conn, _config) do
    conn = Plug.Conn.fetch_query_params(conn)

    with {:ok, operations} <- operations(conn.query_params),
         {:ok, format} <- format(conn.query_params) do
      {:ok,
       %Plan{
         source: %SourcePath{segments: conn.path_info},
         pipelines: [%Pipeline{operations: operations}],
         output: %Output{mode: {:explicit, format}}
       }}
    end
  end

  @impl ImagePipe.Dialect
  def render_error(conn, %Failure{phase: :parse, reason: reason}, _config),
    do: Plug.Conn.send_resp(conn, 400, "declarative fixture: #{inspect(reason)}")

  def render_error(conn, reason, _config),
    do: Plug.Conn.send_resp(conn, 500, "declarative fixture: #{inspect(reason)}")

  # An absent `w` means no geometry at all — the shape the colour-carry parity
  # arm needs, where the only thing that can separate this leg from an ordered
  # dialect asked for the same bytes is the input-colour carry.
  defp operations(%{"w" => raw}) do
    with {:ok, width} <- width(raw),
         {:ok, resize} <- Operation.resize(:fit, {:px, width}, :auto) do
      {:ok, [resize]}
    end
  end

  defp operations(_params), do: {:ok, []}

  defp width(raw) do
    case Integer.parse(raw) do
      {n, ""} when n > 0 -> {:ok, n}
      _other -> {:error, {:invalid_width, raw}}
    end
  end

  defp format(%{"f" => "png"}), do: {:ok, :png}
  defp format(%{"f" => "jpeg"}), do: {:ok, :jpeg}
  defp format(%{"f" => other}), do: {:error, {:invalid_format, other}}
  defp format(_params), do: {:ok, :jpeg}
end
