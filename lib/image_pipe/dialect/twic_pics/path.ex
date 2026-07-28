defmodule ImagePipe.Dialect.TwicPics.Path do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics.Source
  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @spec extract(Plug.Conn.t()) :: {:ok, SourcePath.t(), String.t()} | {:error, term()}
  def extract(%Plug.Conn{} = conn) do
    with {:ok, manipulation} <- fetch_manipulation(conn),
         {:ok, source} <- Source.from_segments(conn.path_info) do
      {:ok, source, manipulation}
    end
  end

  defp fetch_manipulation(%Plug.Conn{} = conn) do
    conn = Plug.Conn.fetch_query_params(conn)

    case Map.get(conn.query_params, "twic") do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_manipulation}
    end
  end
end
