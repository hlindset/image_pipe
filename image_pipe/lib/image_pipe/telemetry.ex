defmodule ImagePipe.Telemetry do
  @moduledoc """
  Attaches ImagePipe's optional Logger handler and span tracer.

  ImagePipe emits `:telemetry` events and attaches no handlers itself.
  `attach_default_logger/1` logs them with `Logger`, and `attach_tracer/1`
  turns them into trace spans. The events are listed in the
  [event reference](telemetry-events.md).
  """

  use Boundary,
    top_level?: true,
    deps: [],
    exports: [
      RequestContext,
      Summary,
      Trace,
      Trace.ReqStep
    ]

  alias ImagePipe.Telemetry.Logger, as: DefaultLogger
  alias ImagePipe.Telemetry.Summary
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Telemetry.Trace.FinchHandler
  alias ImagePipe.Telemetry.Trace.Handler

  @default_prefix [:image_pipe]

  @logger_schema NimbleOptions.new!(
                   level: [
                     type: {:in, Logger.levels()},
                     default: :info,
                     doc:
                       "The level for ordinary lines. Failures and degraded results log at `:warning`."
                   ],
                   events: [
                     type: {:or, [{:in, [:all]}, {:list, {:in, DefaultLogger.all_groups()}}]},
                     default: :all,
                     doc: "`:all`, or a list of the event groups to log. See the groups above."
                   ],
                   prefix: [
                     type: {:custom, __MODULE__, :validate_logger_prefix, []},
                     default: @default_prefix,
                     doc:
                       "The telemetry prefix to subscribe to, a non-empty list of atoms. " <>
                         "Must match the `telemetry_prefix` ImagePipe is configured with."
                   ],
                   stages: [
                     type: :boolean,
                     default: false,
                     doc: """
                     When `true`, also logs a line for each stage of each request, such \
                     as parsing, each cache lookup, decoding, and encoding, for debugging. \
                     By default, each request logs one summary line.
                     """
                   ],
                   debug: [
                     type: :boolean,
                     default: false,
                     doc:
                       "When `true`, also logs each event's raw measurements and metadata " <>
                         "at `:debug`, including operation parameters."
                   ]
                 )

  @spec default_prefix() :: [atom()]
  def default_prefix, do: @default_prefix

  @doc """
  Attaches a `Logger` handler that logs one line per request.

      ImagePipe.Telemetry.attach_default_logger()

  The line is the [`[:request, :summary]`](telemetry-events.md#request-summary)
  event: the method, path, status, duration, and bytes sent, then the
  request's other fields as `key=value`. The fields are also in the line's
  Logger metadata, as a map under `:image_pipe`. Cache sweeps and evictions,
  which belong to no request, log their own lines, and so does a request
  that raised, which has no summary. Failed and dropped cache writes also
  log their own lines, at `:warning`, because a write can finish after its
  request's line. With `stages: true`, every stage of each request
  logs a line as well.

  Call it once at application startup. Calling it again replaces the
  handler's options. Remove it with `detach_default_logger/0`. Setting it up
  is covered in [Monitoring with telemetry](telemetry.md).

  ## Event groups

  `:events` selects groups from the
  [event reference](telemetry-events.md). Without `stages: true`, only these
  have lines: from `:request`, the summary and raised requests, and from
  `:cache`, sweeps, evictions, and failed or dropped writes. The groups are:

    * `:request`: the request summary, and request, processing pool, send,
      deliver, and encode events, except the encode-search probe cost spans,
      which aren't logged.
    * `:parse`: parsing and preset lookup.
    * `:source`: source events.
    * `:transform`: transform and detection events.
    * `:cache`: cache events.
    * `:output`: output format negotiation, info and placeholder bodies, and
      output clamping.
    * `:http_cache`: HTTP cache header events.
    * `:debug`: debug header collection errors.

  ## Log levels

  Lines log at `:level`. A summary line logs at `:error` for a `5xx`
  response or one that failed partway through sending, and at `:warning` for
  a `4xx`, a degraded result, a cache read error, detection whose detector
  failed, was unavailable, or isn't configured, a quality search that missed
  its target or size limit, a result scaled down to fit the limits, or a
  failed `ImagePipe.run/4`. A low-priority request that a full processing
  pool turned away logs at `:level`. With `stages: true`, these stage lines
  log at `:warning`:

    * Exceptions, and results such as `:source_error`, `:cache_error`,
      `:materialize_error`, `:parser_error`, and `:plan_error`.
    * Encode, color-management, output negotiation, info or placeholder, and
      preset lookup failures.
    * Processing pool rejections, timeouts, and worker failures.
    * Detection that fell back to attention (`:unavailable`, `:error`, or no
      detector configured).
    * A quality search with outcome `:best_effort`.
    * An output clamp, a debug collection error, and cache coordination
      results `:busy` and `:bypass`.

  ## Options

  #{NimbleOptions.docs(@logger_schema)}

  Raises `ArgumentError` for invalid options.
  """
  @spec attach_default_logger(keyword()) :: :ok
  def attach_default_logger(opts \\ []) when is_list(opts) do
    opts =
      case NimbleOptions.validate(opts, @logger_schema) do
        {:ok, validated} -> validated
        {:error, error} -> raise ArgumentError, Exception.message(error)
      end

    case DefaultLogger.attach(opts) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detach the default Logger handler."
  @spec detach_default_logger() :: :ok | {:error, :not_found}
  def detach_default_logger, do: DefaultLogger.detach()

  @doc false
  def validate_logger_prefix([_ | _] = prefix) do
    case Enum.all?(prefix, &is_atom/1) do
      true -> {:ok, prefix}
      false -> {:error, "expected a non-empty list of atoms"}
    end
  end

  def validate_logger_prefix(_prefix), do: {:error, "expected a non-empty list of atoms"}

  @tracer_schema NimbleOptions.new!(
                   prefix: [
                     type: {:list, :atom},
                     default: @default_prefix,
                     doc:
                       "The telemetry prefix to subscribe to. Must match the " <>
                         "`telemetry_prefix` ImagePipe is configured with."
                   ],
                   extract_inbound: [
                     type: :boolean,
                     default: false,
                     doc:
                       "When `true`, a request with a valid W3C `traceparent` header continues " <>
                         "the caller's trace, unless a span of your own is already current. " <>
                         "Enable it only when a proxy you control sets the header or removes it " <>
                         "from outside requests. See " <>
                         "[inbound trace context](tracing.md#inbound-trace-context)."
                   ],
                   finch_spans: [
                     type: :boolean,
                     default: true,
                     doc:
                       "Also records a span for each HTTP request a source makes through Finch, " <>
                         "including connection setup. `false` records none."
                   ]
                 )

  @doc """
  Attaches the span tracer, which turns ImagePipe's telemetry events into
  OpenTelemetry spans through the OpenTelemetry API.

      ImagePipe.Telemetry.attach_tracer()

  Your application provides and configures the OpenTelemetry SDK. ImagePipe
  depends on `:opentelemetry_api` as an optional dependency.

  Call it once at application startup. Calling it again replaces the whole
  tracer configuration. Remove it with `detach_tracer/0`. How spans form a
  trace is explained in [Request tracing](tracing.md).

  ## Options

  #{NimbleOptions.docs(@tracer_schema)}

  Raises `ArgumentError` for invalid options, or when ImagePipe was compiled
  without `:opentelemetry_api`. Add `:opentelemetry` to your dependencies and
  recompile ImagePipe (`mix deps.compile image_pipe --force`).
  """
  @spec attach_tracer(keyword()) :: :ok
  def attach_tracer(opts \\ [])

  def attach_tracer(opts) when is_list(opts) do
    opts =
      case NimbleOptions.validate(opts, @tracer_schema) do
        {:ok, validated} ->
          validated

        {:error, %NimbleOptions.ValidationError{} = error} ->
          raise ArgumentError, "invalid attach_tracer options: #{Exception.message(error)}"
      end

    Trace.ensure_available!()
    Trace.set_extract_inbound(opts[:extract_inbound])
    Handler.attach(opts[:prefix])

    case opts[:finch_spans] do
      true -> FinchHandler.attach()
      false -> FinchHandler.detach()
    end

    Trace.set_attached(true)
  end

  def attach_tracer(other) do
    raise ArgumentError,
          "attach_tracer/1 expects a keyword list, got: #{inspect(other)}"
  end

  @doc "Remove the opt-in span tracer attached with `attach_tracer/1`."
  @spec detach_tracer() :: :ok
  def detach_tracer do
    Handler.detach()
    FinchHandler.detach()
    Trace.set_attached(false)
    Trace.set_extract_inbound(false)
  end

  # Maps a request outcome to the request `:result` telemetry vocabulary. Callers
  # stamp this on the `[:request]` span's stop metadata
  # (with `:status`, and `:error` on failures).
  @doc false
  @spec request_result(:ok | :not_modified | {:error, term()}) :: atom()
  def request_result(:ok), do: :ok
  def request_result(:not_modified), do: :not_modified

  def request_result({:error, reason})
      when reason in [
             :missing_signature,
             :invalid_signature,
             :signature_without_keys,
             :invalid_concealed_source,
             :expired
           ],
      do: :parser_error

  def request_result({:error, {:invalid_request, _}}), do: :parser_error
  def request_result({:error, {:invalid_source, _}}), do: :parser_error
  def request_result({:error, {:invalid_output, _}}), do: :plan_error
  def request_result({:error, {:detector, :unavailable}}), do: :plan_error
  def request_result({:error, {:detector, :not_ready}}), do: :plan_error
  def request_result({:error, {:detector, {:unknown_classes, _}}}), do: :plan_error
  def request_result({:error, {:source, _}}), do: :source_error
  def request_result({:error, _reason}), do: :processing_error

  @doc false
  # The `:error` metadata value for a failure reason: its leading atom.
  @spec error_tag(term()) :: atom()
  def error_tag({tag, _value}) when is_atom(tag), do: tag
  def error_tag({tag, _value, _extra}) when is_atom(tag), do: tag
  def error_tag(tag) when is_atom(tag), do: tag
  def error_tag(_reason), do: :error

  # Query parameters that carry an origin's credentials in a presigned source
  # URL: OTel's list for `url.query`, plus the AWS and Google ones it leaves
  # out.
  @credential_params ~w(awsaccesskeyid signature sig x-goog-signature x-goog-credential
                        x-amz-signature x-amz-credential x-amz-security-token)

  @doc false
  # A request's path and query for telemetry, cut at the source: the first
  # `src`, `src64`, or `enc` segment with anything after it is followed by
  # `REDACTED`, and nothing after it is kept. `wm-src64=` tokens become
  # `REDACTED`. A query after a source is the source's own, so it's dropped.
  # Without a source, credential values in the query become `REDACTED`.
  # Nothing is decoded, so the work stays linear in the path's length.
  @spec request_path(String.t(), String.t()) :: String.t()
  def request_path(path, query) do
    case cut_path(String.split(path, "/"), []) do
      {:cut, segments} -> Enum.join(segments, "/")
      {:whole, segments} when query == "" -> Enum.join(segments, "/")
      {:whole, segments} -> Enum.join(segments, "/") <> "?" <> redact_params(query)
    end
  end

  @source_markers ~w(src src64 enc)

  defp cut_path([marker | tail], acc) when marker in @source_markers and tail not in [[], [""]],
    do: {:cut, Enum.reverse(["REDACTED", marker | acc])}

  defp cut_path(["wm-src64=" <> _token | rest], acc),
    do: cut_path(rest, ["wm-src64=REDACTED" | acc])

  defp cut_path([segment | rest], acc), do: cut_path(rest, [segment | acc])
  defp cut_path([], acc), do: {:whole, Enum.reverse(acc)}

  @doc false
  # A parsed source for telemetry: credential values in its query, and any
  # userinfo, become `REDACTED`. The query runs from the first `?` to a `#`,
  # as the origin reads it. A source is decoded from the request without a
  # UTF-8 check, so invalid bytes are replaced and control characters
  # percent-encoded, keeping log lines whole and valid.
  @spec source_url(String.t()) :: String.t()
  def source_url(source) do
    source =
      source
      |> String.replace_invalid()
      |> then(&Regex.replace(~r/[\x00-\x1F\x7F]/, &1, fn char -> "%" <> Base.encode16(char) end))

    {resource, fragment} = split_once(source, "#")
    {base, query} = split_once(resource, "?")
    base = Regex.replace(~r{\A((?:[A-Za-z][A-Za-z0-9+.-]*:)?//)[^/]*@}, base, "\\1REDACTED@")
    query = if query, do: "?" <> redact_params(query), else: ""
    fragment = if fragment, do: "#" <> fragment, else: ""
    base <> query <> fragment
  end

  defp split_once(string, separator) do
    case :binary.split(string, separator) do
      [before, rest] -> {before, rest}
      [whole] -> {whole, nil}
    end
  end

  # Parameters are split on `&` and `;`. A name matches in any case and
  # percent-encoding, as an origin reads it.
  defp redact_params(query), do: query |> redact_params([]) |> IO.iodata_to_binary()

  defp redact_params(query, acc) do
    case :binary.match(query, ["&", ";"]) do
      {position, 1} ->
        pair = binary_part(query, 0, position)
        separator = binary_part(query, position, 1)
        rest = binary_part(query, position + 1, byte_size(query) - position - 1)
        redact_params(rest, [acc, redact_param(pair), separator])

      :nomatch ->
        [acc, redact_param(query)]
    end
  end

  defp redact_param(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, _value] -> if credential_param?(name), do: name <> "=REDACTED", else: pair
      [_name] -> pair
    end
  end

  defp credential_param?(name), do: String.downcase(URI.decode(name)) in @credential_params

  @doc false
  @spec span(keyword(), [atom()], map() | keyword(), (-> term())) :: term()
  def span(opts, stage, start_metadata, fun) when is_function(fun, 0) do
    do_span(opts, stage, start_metadata, fn start_metadata ->
      {result, stop_metadata} = fun.()
      {result, merge_metadata(start_metadata, stop_metadata)}
    end)
  end

  # Handle for a manually bracketed span. See `start_span/3`.
  @typedoc false
  @opaque span_handle() :: %{
            event: [atom()],
            stage: [atom()],
            start_time: integer(),
            start_metadata: map(),
            closed: :atomics.atomics_ref()
          }

  # Opens a span that closes independently of a function return.
  #
  # For example, `ImagePipe.Decode.with_image/4` closes its fetch/decode span
  # inside the source bracket, before running the caller's continuation.
  #
  # Mirrors `:telemetry.span/3`'s event names, measurement keys (`:monotonic_time`
  # + `:system_time` on `:start`; `:duration` + `:monotonic_time` on
  # `:stop`/`:exception`), and metadata semantics (start metadata merged into the
  # stop metadata, `telemetry_span_context` on every phase, matching `span/4`).
  #
  # `stop_span/2` and `exception_span/4` are single-shot: the first close wins and
  # later calls no-op, so a surrounding catch-all may emit `exception_span/4`
  # unconditionally without re-closing a span that already stopped.
  @doc false
  @spec start_span(keyword(), [atom()], map() | keyword()) :: span_handle()
  def start_span(opts, stage, start_metadata) when is_list(stage) do
    event = event_prefix(opts, stage)

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
      stage: stage,
      start_time: start_time,
      start_metadata: start_metadata,
      closed: :atomics.new(1, signed: false)
    }
  end

  # Closes a `start_span/3` bracket with a `:stop` event. Single-shot.
  @doc false
  @spec stop_span(span_handle(), map() | keyword()) :: :ok
  def stop_span(handle, stop_metadata) do
    close_span(handle, :stop, merge_metadata(handle.start_metadata, stop_metadata))
  end

  # Closes a `start_span/3` bracket with an `:exception` event. Single-shot.
  @doc false
  @spec exception_span(span_handle(), Exception.kind(), term(), Exception.stacktrace()) :: :ok
  def exception_span(handle, kind, reason, stacktrace) do
    metadata =
      Map.merge(handle.start_metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})

    close_span(handle, :exception, metadata)
  end

  defp close_span(handle, phase, metadata) do
    if :atomics.compare_exchange(handle.closed, 1, 0, 1) == :ok do
      stop_time = System.monotonic_time()
      duration = stop_time - handle.start_time

      :telemetry.execute(
        handle.event ++ [phase],
        %{duration: duration, monotonic_time: stop_time},
        metadata
      )

      if phase == :stop, do: Summary.record(handle.stage, duration, metadata)
    end

    :ok
  end

  @doc false
  @spec execute(keyword(), [atom()], map() | keyword(), map() | keyword()) :: :ok
  def execute(opts, stage, measurements, metadata) when is_list(stage) do
    metadata = clean_metadata(metadata)

    opts
    |> event_prefix(stage)
    |> :telemetry.execute(Map.new(measurements), metadata)

    Summary.record(stage, nil, metadata)
  end

  # Inert options the request wrote, which parsing dropped: their URL keys and
  # locations. Never their values, which come from the URL.
  @doc false
  @spec ignored_options(keyword(), [String.t()], [struct()]) :: :ok
  def ignored_options(opts, keys, issues) do
    execute(opts, [:request, :ignored_options], %{}, %{
      options: keys,
      locations: Enum.flat_map(issues, & &1.locations)
    })
  end

  # The span and event functions take a configuration or options list and
  # read only its `:telemetry_prefix`. This narrows the list to that key,
  # for options that are kept, sent to another process, or handed to code
  # outside the request's configuration.
  @doc false
  @spec telemetry_opts(keyword()) :: keyword()
  def telemetry_opts(opts) when is_list(opts) do
    Keyword.take(opts, [:telemetry_prefix])
  end

  defp do_span(opts, stage, start_metadata, span_fun) when is_list(stage) do
    start_metadata = clean_metadata(start_metadata)
    prefix = Keyword.get(opts, :telemetry_prefix, @default_prefix)
    if stage == [:request], do: Summary.open(prefix, start_metadata)
    started = System.monotonic_time()

    {result, stop_metadata} =
      try do
        :telemetry.span(prefix ++ stage, start_metadata, fn ->
          {result, stop_metadata} = span_fun.(start_metadata)
          {{result, stop_metadata}, stop_metadata}
        end)
      catch
        kind, reason ->
          if stage == [:request], do: Summary.discard()
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    duration = System.monotonic_time() - started

    case stage do
      [:request] -> Summary.close(prefix, duration, stop_metadata)
      _stage -> Summary.record(stage, duration, stop_metadata)
    end

    result
  end

  defp event_prefix(opts, stage) when is_list(opts) and is_list(stage) do
    Keyword.get(opts, :telemetry_prefix, @default_prefix) ++ stage
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
