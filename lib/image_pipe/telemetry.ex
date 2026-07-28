defmodule ImagePipe.Telemetry do
  @moduledoc """
  Telemetry helpers and an opt-in default Logger handler for ImagePipe.

  ImagePipe emits `:telemetry` events only. Hosts attach their own handlers
  (metrics, OpenTelemetry, APM). For convenience, `attach_default_logger/1`
  attaches a stdlib `Logger` handler covering ImagePipe's events.
  """

  use Boundary,
    top_level?: true,
    deps: [],
    exports: [
      Trace,
      Trace.Stack,
      Trace.Context,
      Trace.Span,
      Trace.Exporter,
      Trace.ReqStep,
      Trace.OpenTelemetryExporter,
      Trace.OtelReplay
    ]

  alias ImagePipe.Telemetry.Logger, as: DefaultLogger
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.Capture
  alias ImagePipe.Telemetry.Trace.FinchCapture

  @default_prefix [:image_pipe]

  @valid_levels Logger.levels()

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

  @doc """
  Attach the default `Logger` handler for ImagePipe telemetry. Opt-in and
  idempotent.

  Raises `ArgumentError` on invalid options. This is host-startup configuration,
  so it raises (matching `Oban.Telemetry.attach_default_logger` /
  `Phoenix.Logger`) rather than returning a tagged error.

  Options:
    * `:level` — base log level (default `:info`); errors/exceptions escalate to `:warning`.
    * `:events` — `:all` (default) or a list of `[:request, :parse, :source, :transform, :cache]`.
    * `:prefix` — telemetry event prefix list (default `#{inspect(@default_prefix)}`).
    * `:debug` — when `true`, also log the full raw measurements/metadata (default `false`).
  """
  @spec attach_default_logger(keyword()) :: :ok
  def attach_default_logger(opts \\ []) when is_list(opts) do
    :ok = validate_logger_opts(opts)

    case DefaultLogger.attach(opts) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the default Logger handler."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: DefaultLogger.detach()

  defp validate_logger_opts(opts) do
    known = [:level, :events, :prefix, :debug]

    with [] <- Keyword.keys(opts) -- known,
         :ok <- validate_events(Keyword.get(opts, :events, :all)),
         :ok <- validate_level(Keyword.get(opts, :level, :info)),
         :ok <- validate_debug(Keyword.get(opts, :debug, false)) do
      validate_prefix(Keyword.get(opts, :prefix, @default_prefix))
    else
      unknown when is_list(unknown) ->
        raise ArgumentError, "unknown attach_default_logger options: #{inspect(unknown)}"
    end
  end

  defp validate_events(:all), do: :ok

  defp validate_events(groups) when is_list(groups) do
    case groups -- DefaultLogger.all_groups() do
      [] -> :ok
      bad -> raise ArgumentError, "unknown telemetry logger event groups: #{inspect(bad)}"
    end
  end

  defp validate_events(other),
    do: raise(ArgumentError, ":events must be :all or a list, got: #{inspect(other)}")

  defp validate_level(level) when level in @valid_levels, do: :ok

  defp validate_level(other),
    do: raise(ArgumentError, ":level must be a valid Logger level, got: #{inspect(other)}")

  defp validate_debug(debug) when is_boolean(debug), do: :ok

  defp validate_debug(other),
    do: raise(ArgumentError, ":debug must be a boolean, got: #{inspect(other)}")

  defp validate_prefix(prefix) when is_list(prefix) and prefix != [] do
    if Enum.all?(prefix, &is_atom/1) do
      :ok
    else
      raise ArgumentError, ":prefix must be a non-empty list of atoms, got: #{inspect(prefix)}"
    end
  end

  defp validate_prefix(other),
    do: raise(ArgumentError, ":prefix must be a non-empty list of atoms, got: #{inspect(other)}")

  @tracer_schema NimbleOptions.new!(
                   exporter: [type: :atom, required: true],
                   prefix: [type: {:list, :atom}, default: @default_prefix],
                   extract_inbound: [type: :boolean, default: false],
                   finch_spans: [type: :boolean, default: true]
                 )

  @doc """
  Attach the opt-in span tracer. See `ImagePipe.Telemetry.Trace`.

  Host-startup configuration, so it raises `ArgumentError` on invalid options
  (unknown keys, wrong types, or an exporter module that is not loadable or does
  not export `export/1`) rather than returning a tagged error.

  Options:
    * `:exporter` — required; a module implementing `ImagePipe.Telemetry.Trace.Exporter`.
    * `:prefix` — telemetry event prefix list (default `#{inspect(@default_prefix)}`).
    * `:extract_inbound` — extract a W3C `traceparent` from inbound requests (default `false`).
    * `:finch_spans` — also capture physical Finch wire spans (default `true`).
  """
  @spec attach_tracer(keyword()) :: :ok
  def attach_tracer(opts) when is_list(opts) do
    opts =
      case NimbleOptions.validate(opts, @tracer_schema) do
        {:ok, validated} ->
          validated

        {:error, %NimbleOptions.ValidationError{} = error} ->
          raise ArgumentError, "invalid attach_tracer options: #{Exception.message(error)}"
      end

    exporter = opts[:exporter]

    unless Code.ensure_loaded?(exporter) and function_exported?(exporter, :export, 1) do
      raise ArgumentError,
            "exporter #{inspect(exporter)} must be a loaded module exporting export/1"
    end

    if function_exported?(exporter, :ready?, 0) and not exporter.ready?() do
      raise ArgumentError,
            "exporter #{inspect(exporter)} is not ready: ready?/0 returned false " <>
              "(check the exporter's documentation for its required dependencies or configuration)"
    end

    Trace.set_exporter(exporter)
    Trace.set_extract_inbound(opts[:extract_inbound])
    Capture.attach(%{prefix: opts[:prefix], exporter: exporter})

    if opts[:finch_spans] do
      FinchCapture.attach(%{exporter: exporter})
    end

    :ok
  end

  def attach_tracer(other) do
    raise ArgumentError,
          "attach_tracer/1 expects a keyword list, got: #{inspect(other)}"
  end

  @doc "Remove the opt-in span tracer attached with `attach_tracer/1`."
  @spec detach_tracer() :: :ok
  def detach_tracer do
    Capture.detach()
    FinchCapture.detach()
    Trace.set_exporter(nil)
    Trace.set_extract_inbound(false)
    :ok
  end

  @doc """
  Maps a request outcome to the `:result` telemetry vocabulary shared by every
  dialect Plug. Callers stamp this on the `[:request]` span's stop metadata
  (with `:status`, and `:error` on failures).
  """
  @spec request_result(:ok | :not_modified | {:error, term()}) :: atom()
  def request_result(:ok), do: :ok
  def request_result(:not_modified), do: :not_modified
  def request_result({:error, {:source, _}}), do: :source_error
  def request_result({:error, {:cache_write, _}}), do: :cache_error

  def request_result({:error, tag}) when tag in [:invalid_output_plan, :invalid_pipeline_plan],
    do: :plan_error

  def request_result({:error, {tag, _}})
      when tag in [:invalid_output_plan, :invalid_pipeline_plan],
      do: :plan_error

  def request_result({:error, :empty_pipeline_plan}), do: :plan_error
  def request_result({:error, _reason}), do: :processing_error

  @spec span(keyword(), [atom()], map() | keyword(), (-> term())) :: term()
  def span(telemetry_opts, stage, start_metadata, fun) when is_function(fun, 0) do
    do_span(telemetry_opts, stage, start_metadata, fn start_metadata ->
      {result, stop_metadata} = fun.()
      {result, merge_metadata(start_metadata, stop_metadata)}
    end)
  end

  @typedoc "Handle for a manually bracketed span. See `start_span/3`."
  @opaque span_handle() :: %{
            event: [atom()],
            start_time: integer(),
            start_metadata: map(),
            closed: :atomics.atomics_ref()
          }

  @doc """
  Opens a manual span bracket for the one case `span/4` cannot express: a span
  whose close site is not a function boundary (`ImagePipe.Decode.with_image/4`'s
  `[:source, :fetch_decode]` span must close *inside* the source bracket,
  after decode but before the caller's build continuation runs).

  Mirrors `:telemetry.span/3`'s event names, measurement keys (`:monotonic_time`
  + `:system_time` on `:start`; `:duration` + `:monotonic_time` on
  `:stop`/`:exception`), and metadata semantics (start metadata merged into the
  stop metadata, `telemetry_span_context` on every phase, matching `span/4`).

  `stop_span/2` and `exception_span/4` are single-shot: the first close wins and
  later calls no-op, so a surrounding catch-all may emit `exception_span/4`
  unconditionally without re-closing a span that already stopped.
  """
  @spec start_span(keyword(), [atom()], map() | keyword()) :: span_handle()
  def start_span(telemetry_opts, stage, start_metadata) when is_list(stage) do
    event = event_prefix(telemetry_opts, stage)

    start_metadata =
      start_metadata
      |> clean_metadata()
      |> Map.put_new(:telemetry_span_context, make_ref())

    start_time = System.monotonic_time()

    :telemetry.execute(
      event ++ [:start],
      %{monotonic_time: start_time, system_time: System.system_time()},
      start_metadata
    )

    %{
      event: event,
      start_time: start_time,
      start_metadata: start_metadata,
      closed: :atomics.new(1, signed: false)
    }
  end

  @doc "Closes a `start_span/3` bracket with a `:stop` event. Single-shot."
  @spec stop_span(span_handle(), map() | keyword()) :: :ok
  def stop_span(handle, stop_metadata) do
    close_span(handle, :stop, merge_metadata(handle.start_metadata, stop_metadata))
  end

  @doc "Closes a `start_span/3` bracket with an `:exception` event. Single-shot."
  @spec exception_span(span_handle(), Exception.kind(), term(), Exception.stacktrace()) :: :ok
  def exception_span(handle, kind, reason, stacktrace) do
    metadata =
      Map.merge(handle.start_metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})

    close_span(handle, :exception, metadata)
  end

  defp close_span(handle, phase, metadata) do
    if :atomics.compare_exchange(handle.closed, 1, 0, 1) == :ok do
      stop_time = System.monotonic_time()

      :telemetry.execute(
        handle.event ++ [phase],
        %{duration: stop_time - handle.start_time, monotonic_time: stop_time},
        metadata
      )
    end

    :ok
  end

  @spec execute(keyword(), [atom()], map() | keyword(), map() | keyword()) :: :ok
  def execute(telemetry_opts, stage, measurements, metadata) when is_list(stage) do
    telemetry_opts
    |> event_prefix(stage)
    |> :telemetry.execute(Map.new(measurements), clean_metadata(metadata))
  end

  @spec telemetry_opts(keyword()) :: keyword()
  def telemetry_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:telemetry_prefix])
  end

  defp do_span(telemetry_opts, stage, start_metadata, span_fun) when is_list(stage) do
    start_metadata = clean_metadata(start_metadata)

    :telemetry.span(event_prefix(telemetry_opts, stage), start_metadata, fn ->
      span_fun.(start_metadata)
    end)
  end

  defp event_prefix(telemetry_opts, stage) when is_list(telemetry_opts) and is_list(stage) do
    Keyword.get(telemetry_opts, :telemetry_prefix, @default_prefix) ++ stage
  end

  defp clean_metadata(metadata) do
    metadata
    |> Map.new()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp merge_metadata(left, right) do
    left
    |> clean_metadata()
    |> Map.merge(clean_metadata(right))
  end
end
