defmodule ImagePipe.Dialect.TwicPics do
  @moduledoc """
  ImagePipe's TwicPics-compatible URL dialect, implemented as an
  `ImagePipe.Dialect` — mounted through `plug ImagePipe.Plug, dialect:
  ImagePipe.Dialect.TwicPics, <flat config>`.

  The dialect owns parsing the positional TwicPics manipulation, source
  translation and negotiation input, ordered pipeline execution, and error
  rendering; the shared runner in `ImagePipe.Plug` owns the request
  lifecycle around them.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Config,
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour ImagePipe.Dialect

  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.Negotiation, as: DialectNegotiation
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Errors
  alias ImagePipe.Dialect.TwicPics.Identity
  alias ImagePipe.Dialect.TwicPics.Manipulation
  alias ImagePipe.Dialect.TwicPics.Path
  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Error
  alias ImagePipe.Plan.Operation, as: PlanOperation
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  @impl ImagePipe.Dialect
  def validate_config!(opts), do: Config.validate!(opts)

  @impl ImagePipe.Dialect
  def parse(%Plug.Conn{} = conn, config) do
    result =
      with {:ok, source, manipulation} <- Path.extract(conn),
           {:ok, chain} <- Manipulation.parse(manipulation) do
        RequestBuilder.build(source, chain, config)
      end

    runner_result =
      case result do
        {:error, reason} -> {:error, %Failure{phase: :parse, reason: reason}}
        success -> success
      end

    {runner_result, parse_stop_metadata(result)}
  end

  # ex_dna:disable-for-next-line
  defp parse_stop_metadata({:ok, %Request{}}), do: %{result: :ok}

  defp parse_stop_metadata({:error, reason}),
    do: %{result: :error, error: Error.tag(reason)}

  @impl ImagePipe.Dialect
  def prepare(%Plug.Conn{} = conn, %Request{} = request, config) do
    {:ok,
     %Resolved{
       request: request,
       source: request.source,
       negotiation: fn -> negotiation_result(conn, request, config) end,
       response_meta: request.response,
       operations: operation_names(request),
       auto_rotate?: request.auto_rotate,
       debug?: request.response.debug?,
       http_cache: :dialect_owned,
       terminal: :image
     }}
  end

  # The runner invokes this thunk only after `Source.resolve/3`. Negotiation,
  # detector callbacks, and identity construction therefore keep the chain's
  # source-before-negotiation execution and error precedence.
  defp negotiation_result(conn, %Request{} = request, config) do
    case DialectNegotiation.negotiate(conn, request.output, config) do
      {:ok, negotiation} ->
        {:ok, negotiation,
         Identity.material(request, negotiation, conn, config, detector_identity(request, config))}

      {:error, _reason} = error ->
        error
    end
  end

  @impl ImagePipe.Dialect
  def decode_request(%Request{} = request, geometry),
    do: Pipeline.decode_request(request, geometry)

  @impl ImagePipe.Dialect
  # The hand-written dialects' contract delegations are textually identical but
  # resolve through per-dialect aliases to different Request structs and
  # Pipeline modules — irreducible without a macro that would force a
  # naming convention on every dialect and hide the contract.
  # ex_dna:disable-for-next-line
  def execute(state, geometry, %Request{} = request, opts) do
    ImagePipe.Dialect.safe_transform(fn -> Pipeline.run(state, geometry, request, opts) end)
  end

  # A parse rejection renders this dialect's 400 protocol; every later phase
  # renders through the core stage table. The phase is read off the wrapper
  # rather than inferred from the reason, so an unrecognized parse reject
  # cannot drift into a stage status.
  @impl ImagePipe.Dialect
  def render_error(conn, %Failure{phase: :parse, reason: reason}, config),
    do: Errors.send_parse(conn, reason, config)

  def render_error(conn, reason, config), do: Errors.send(conn, reason, config)

  @impl ImagePipe.Dialect
  def classify_error(%Failure{phase: :parse}), do: :parser_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})

  defp detector_identity(%Request{steps: steps}, config) do
    case face_assist?(steps) do
      true ->
        Transform.detector_identity(
          Keyword.get(config, :detector, :default),
          Keyword.put(config, :classes, ["face"])
        )

      false ->
        nil
    end
  end

  defp face_assist?(steps) do
    steps
    |> Enum.reduce_while(:inactive, fn
      :set_auto_focus, _mode -> {:cont, :active}
      {:set_focus, _operand}, _mode -> {:cont, :inactive}
      {:operation, %ImagePipe.Plan.Operation.CropRegion{}}, _mode -> {:cont, :inactive}
      {:focused, _operation}, :active -> {:halt, :used}
      _step, mode -> {:cont, mode}
    end)
    |> Kernel.==(:used)
  end

  defp operation_names(%Request{steps: steps}) do
    for {kind, operation} <- steps,
        kind in [:operation, :focused],
        do: PlanOperation.name(operation)
  end
end
