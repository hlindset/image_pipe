defmodule ImagePipe.Dialect.Declarative do
  @moduledoc """
  The declarative tier of the `ImagePipe.Dialect` contract (design decision U6).

  A dialect whose whole request is expressible as a product-neutral
  `%ImagePipe.Plan{}` implements ONE parse callback and gets the rest of the
  lifecycle from this base:

      defmodule MyApp.Dialect do
        use ImagePipe.Dialect.Declarative

        @impl ImagePipe.Dialect.Declarative
        def parse_plan(conn, config), do: {:ok, %ImagePipe.Plan{...}}

        @impl ImagePipe.Dialect
        def render_error(conn, reason, config), do: ...

        @impl ImagePipe.Dialect
        def validate_config!(opts), do: ...
      end

  Mount it exactly like an ordered dialect:

      plug ImagePipe.Plug, dialect: MyApp.Dialect, sources: [...]

  This is not a second lifecycle. Same behaviour, same runner, same mount — the
  runner never branches on which base produced the
  `%ImagePipe.Dialect.Resolved{}`. The ordered/declarative distinction is only
  about who owns the transform stage: an ordered dialect runs its own pipeline
  in `c:ImagePipe.Dialect.execute/4`, a declarative one runs the fixed neutral
  driver.

  `parse_plan/2` is deliberately NOT named `parse/2`: this base implements the
  behaviour's `parse/2` (the `[:parse]` span's stop metadata and the parse-phase
  `%ImagePipe.Dialect.Failure{}` wrapper) on top of it.

  ## What your `render_error/3` receives

  A parse rejection arrives wrapped as `%ImagePipe.Dialect.Failure{phase: :parse,
  reason: your_reason}`; every other failure arrives as a bare reason. Match the
  wrapper to render client errors for parse rejections you do not recognize,
  without inferring provenance from a tag allowlist. `classify_error/1` is
  injected with a sensible default and is `defoverridable` — an override must
  re-declare `@impl ImagePipe.Dialect`.

  ## Expiry

  This tier does not enforce `%ImagePipe.Plan{}`'s `expires` field. A host
  dialect that needs request expiry must reject expired requests itself,
  inside its own `parse_plan/2`.
  """

  alias ImagePipe.Decode
  alias ImagePipe.Dialect.Declarative.Identity
  alias ImagePipe.Dialect.Failure
  alias ImagePipe.Dialect.Negotiation
  alias ImagePipe.Dialect.RenderTerminal
  alias ImagePipe.Dialect.Resolved
  alias ImagePipe.Error
  alias ImagePipe.Plan
  alias ImagePipe.Plan.RenderContext
  alias ImagePipe.Plan.SourceInfo
  alias ImagePipe.Renderer
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.DecodePlanner
  alias ImagePipe.Transform.InputColorManagement
  alias ImagePipe.Transform.PendingOrientation
  alias ImagePipe.Transform.SourceGeometry
  alias ImagePipe.Transform.State
  alias Vix.Vips.Image, as: VipsImage

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Decode,
      ImagePipe.Dialect,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Plan,
      ImagePipe.Renderer,
      ImagePipe.Representation,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @doc """
  Parses a request into a product-neutral plan. The base wraps this in the
  behaviour's `c:ImagePipe.Dialect.parse/2` and its `[:parse]` span.
  """
  @callback parse_plan(Plug.Conn.t(), keyword()) ::
              {:ok, Plan.t()}
              | {:redirect, pos_integer(), String.t()}
              | {:error, term()}

  @config_keys [:http_cache, :detector, :detector_required, :storage_inputs]

  @config_schema NimbleOptions.new!(
                   http_cache: [
                     type: :keyword_list,
                     default: [mode: :disabled],
                     keys: [mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]]
                   ],
                   detector: [type: {:or, [{:in, [:default, nil]}, :atom]}, default: :default],
                   detector_required: [type: :boolean, default: false],
                   storage_inputs: [
                     type:
                       {:list,
                        {:custom, ImagePipe.Dialect.SharedConfig, :validate_storage_input, []}},
                     default: []
                   ]
                 )

  @doc """
  The config keys this base reads, for a declarative dialect's own
  `c:ImagePipe.Dialect.validate_config!/1` to split on — the same delegation
  shape `ImagePipe.Dialect.SharedConfig.keys/0` uses.
  """
  @spec config_keys() :: [atom()]
  def config_keys, do: @config_keys

  @doc "Validates and defaults the keys `config_keys/0` names. Raises on invalid input."
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case NimbleOptions.validate(Keyword.take(opts, @config_keys), @config_schema) do
      {:ok, validated} ->
        Keyword.merge(opts, validated)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe declarative dialect options: #{Exception.message(error)}"
    end
  end

  defmacro __using__(_opts) do
    # The base is injected as a resolved module atom rather than an alias: the
    # using module owns its own alias scope, and an alias the host happens to
    # rebind must not redirect the contract delegations. `__MODULE__` inside the
    # quote still resolves to the using module, which is what `parse/3` and
    # `prepare/4` need.
    base = __MODULE__

    quote do
      @behaviour ImagePipe.Dialect
      @behaviour unquote(base)

      @impl ImagePipe.Dialect
      def parse(conn, config), do: unquote(base).parse(__MODULE__, conn, config)

      @impl ImagePipe.Dialect
      def prepare(conn, plan, config),
        do: unquote(base).prepare(__MODULE__, conn, plan, config)

      @impl ImagePipe.Dialect
      def decode_request(plan, geometry), do: unquote(base).decode_request(plan, geometry)

      @impl ImagePipe.Dialect
      def execute(state, geometry, plan, opts),
        do: unquote(base).execute(state, geometry, plan, opts)

      @impl ImagePipe.Dialect
      def classify_error(reason), do: unquote(base).classify_error(reason)

      defoverridable classify_error: 1
    end
  end

  # -- parse ------------------------------------------------------------------

  @doc false
  def parse(dialect, %Plug.Conn{} = conn, config) do
    result = dialect.parse_plan(conn, config)
    {wrap_parse_failure(result), parse_stop_metadata(result)}
  end

  defp wrap_parse_failure({:error, reason}), do: {:error, %Failure{phase: :parse, reason: reason}}
  defp wrap_parse_failure(result), do: result

  defp parse_stop_metadata({:ok, %Plan{}}), do: %{result: :ok}

  defp parse_stop_metadata({:redirect, status, _location}),
    do: %{result: :redirect, status: status}

  defp parse_stop_metadata({:error, reason}), do: %{result: :error, error: Error.tag(reason)}

  # -- prepare ----------------------------------------------------------------

  @doc false
  def prepare(dialect, %Plug.Conn{} = conn, %Plan{} = plan, config) do
    with {:ok, _pipelines} <- validate_plan(plan),
         :ok <- check_detector(plan, config) do
      {:ok,
       %Resolved{
         request: plan,
         source: plan.source,
         negotiation: fn -> negotiation_result(dialect, conn, plan, config) end,
         response_meta: plan.response,
         operations: Plan.operation_names(plan),
         auto_rotate?: plan.auto_rotate,
         debug?: plan.response.debug?,
         http_cache: :generated,
         terminal: terminal(plan)
       }}
    end
  end

  # `parse_plan/2` is a host callback, so its return value is a real boundary:
  # validate the plan's shape here rather than trusting it.
  defp validate_plan(%Plan{} = plan) do
    case Transform.validate_prefetch_safe_plan(plan) do
      {:ok, _pipelines} = ok -> ok
      {:error, reason} -> {:error, {:plan_validation, reason}}
    end
  end

  # Strict-mode capability gate: when the host opts into `detector_required`
  # and the plan asks for content detection, reject up-front. Availability is a
  # cheap load check (no I/O), so it runs before any source fetch or cache read.
  defp check_detector(%Plan{} = plan, config) do
    classes = Plan.detect_classes(plan)

    if Keyword.get(config, :detector_required, false) and classes != nil do
      config = Keyword.put(config, :classes, classes)

      if Transform.detector_available?(Keyword.get(config, :detector, :default), config),
        do: :ok,
        else: {:error, {:detector, :unavailable}}
    else
      :ok
    end
  end

  # The thunk is invoked by the runner only after `ImagePipe.Source.resolve/3`,
  # preserving source-before-negotiation error precedence — and keeping the
  # detector-identity callback (a host callback) behind a successful resolve.
  defp negotiation_result(dialect, conn, %Plan{output: nil} = plan, config) do
    negotiation = Negotiation.terminal(:render)
    {:ok, negotiation, material(dialect, plan, negotiation, conn, config)}
  end

  defp negotiation_result(dialect, conn, %Plan{} = plan, config) do
    case Negotiation.negotiate(conn, plan.output, config) do
      {:ok, negotiation} ->
        {:ok, negotiation, material(dialect, plan, negotiation, conn, config)}

      {:error, _reason} = error ->
        error
    end
  end

  defp material(dialect, plan, negotiation, conn, config) do
    Identity.material(dialect, plan, negotiation, conn, config, detector_identity(plan, config))
  end

  defp detector_identity(%Plan{} = plan, config) do
    classes = Plan.detect_classes(plan)

    if classes != nil or Plan.face_assist?(plan) do
      config = Keyword.put(config, :classes, classes || ["face"])
      Transform.detector_identity(Keyword.get(config, :detector, :default), config)
    end
  end

  # -- terminal ---------------------------------------------------------------

  defp terminal(%Plan{render: :image}), do: :image

  defp terminal(%Plan{render: {:custom, _module, params} = spec}) do
    {:render,
     %RenderTerminal{
       cache: :none,
       offers: Map.get(params, :offers, []),
       fun: fn resolved_source, config -> render(spec, resolved_source, config) end
     }}
  end

  # Bridges to the `ImagePipe.Renderer` facade, which owns the `[:render]` span.
  # A renderer declares its depth with `requires/1`; today the only depth is
  # `:header`, satisfied by the decode bracket's header open.
  #
  # `Renderer.run/3` runs AFTER the bracket closes, not inside it: a renderer is
  # host code and has no business running inside the decode bracket's cleanup
  # scope. The `%SourceInfo{}` it needs is a plain value, so it travels out.
  defp render(spec, resolved_source, config) do
    info =
      Decode.with_image(
        resolved_source,
        Keyword.put(config, :auto_rotate?, false),
        fn _geometry -> %DecodePlanner.Request{} end,
        fn %State{} = state, %SourceGeometry{} = geometry ->
          {:ok, source_info(state, geometry)}
        end
      )

    with {:ok, %SourceInfo{} = info} <- info,
         {:ok, {content_type, body}} <- Renderer.run(spec, %RenderContext{info: info}, config) do
      {:ok, content_type, body}
    else
      # Every failure — fetch, decode, input limit, and the renderer's own —
      # carries the `{:render, _}` envelope, so a dialect's error module can
      # distinguish a render-terminal failure from an image-terminal one and
      # unwrap the inner families it renders specifically.
      {:error, reason} -> {:error, {:render, reason}}
    end
  end

  # `SourceInfo.width`/`height` are the STORED (pre-orientation) dimensions and
  # `orientation` is the raw EXIF tag read from the decoded image — NOT from
  # `geometry.debug_facts`, whose collection is best-effort and degrades to
  # `%{}` on failure, which would silently report orientation 1 and hand a
  # renderer the wrong display dimensions. The bracket is opened with
  # `auto_rotate?: false`, so `geometry.storage_dimensions` is the stored frame.
  # `byte_size` stays nil.
  defp source_info(%State{image: image}, %SourceGeometry{} = geometry) do
    {width, height} = geometry.storage_dimensions

    %SourceInfo{
      format: geometry.source_format,
      width: width,
      height: height,
      orientation: exif_orientation(image),
      byte_size: nil
    }
  end

  defp exif_orientation(image) do
    case VipsImage.header_value(image, "orientation") do
      {:ok, value} when is_integer(value) and value in 1..8 -> value
      _other -> 1
    end
  end

  # -- decode + execute -------------------------------------------------------

  @doc false
  def decode_request(%Plan{} = plan, %SourceGeometry{} = geometry) do
    DecodePlanner.request_from_chain(
      first_pipeline_operations(plan),
      geometry.storage_dimensions,
      PendingOrientation.quarter_turn?(geometry.pending_orientation)
    )
  end

  defp first_pipeline_operations(%Plan{pipelines: [%{operations: operations} | _rest]}),
    do: operations

  defp first_pipeline_operations(%Plan{pipelines: []}), do: []

  @doc false
  def execute(%State{} = state, %SourceGeometry{}, %Plan{} = plan, opts) do
    ImagePipe.Dialect.safe_transform(fn ->
      plan
      |> Transform.execute_plan(state, Keyword.put(opts, :seed_input_color_management, true))
      |> case do
        # `stamp_carry/1` is the ONLY writer of the icc-imported/icc-backup
        # headers the encoder's colorspace-to-result step reads. Skipping it
        # makes the encoder take its "no import ran" branch on an imported
        # image — correct output profile header, wrong pixels. Every pipeline
        # that runs the import preamble must also run this.
        {:ok, %State{} = state} -> {:ok, InputColorManagement.stamp_carry(state)}
        {:error, {:materialize_error, reason}} -> {:error, {:decode, reason}}
        {:error, _reason} = error -> error
      end
    end)
  end

  # -- error classification ---------------------------------------------------

  @doc false
  def classify_error(%Failure{phase: :parse}), do: :parser_error
  def classify_error({:plan_validation, _reason}), do: :plan_error
  def classify_error({:detector, :unavailable}), do: :plan_error
  def classify_error(reason), do: Telemetry.request_result({:error, reason})
end
