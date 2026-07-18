defmodule ImagePipe.Test.AutomaticIIIFParser do
  @moduledoc false

  @behaviour ImagePipe.Parser

  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Parser.IIIF
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output

  @impl ImagePipe.Parser
  def validate_options!(opts), do: IIIF.validate_options!(opts)

  @impl ImagePipe.Parser
  def parse(conn, opts) do
    case IIIF.parse(conn, opts) do
      {:ok, %Plan{output: %Output{} = output} = plan} ->
        {:ok, %Plan{plan | output: %Output{output | mode: :automatic}}}

      result ->
        result
    end
  end

  @impl ImagePipe.Parser
  def handle_error(conn, error), do: IIIF.handle_error(conn, error)
end
