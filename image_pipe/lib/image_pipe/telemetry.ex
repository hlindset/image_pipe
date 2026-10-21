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
  which belong to no request, log their own lines. Failed and dropped cache
  writes also log their own lines, at `:warning`, because a write can finish
  after its request's line. With `stages: true`, every stage of each request
  logs a line as well.

  Call it once at application startup. Calling it again replaces the
  handler's options. Remove it with `detach_default_logger/0`. Setting it up
  is covered in [Monitoring with telemetry](telemetry.md).

  ## Event groups

  `:events` selects groups from the
  [event reference](telemetry-events.md). Without `stages: true`, only the
  `:request` group's summary and the `:cache` group's sweeps, evictions, and
  failed or dropped writes have lines:

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
  def request_result({:error, {:preset, :too_many_presets}}), do: :parser_error
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
  # A request's path and query for telemetry, as sent, unless a source URL in
  # it carries credentials:
  #
  #   * the query string's credential values become `REDACTED`
  #   * a `src` URL carrying them is logged decoded, as the source parser reads
  #     it, with those values `REDACTED`
  #   * a `src64` or `wm-src64` URL carrying them, in any base64 spelling,
  #     percent-encoded or not, becomes `REDACTED` whole
  #
  # It runs on every request before the signature is checked, so its work
  # stays linear in the path's length.
  @spec request_path(String.t(), String.t()) :: String.t()
  def request_path(path, ""), do: redact_path(path)

  def request_path(path, query),
    do: redact_path(path) <> "?" <> redact_params(query, &redact_src_param/1)

  @source_markers ~w(src src64 enc)

  # The source is the path's tail and can hold `/`, so it's split off after
  # the `wm-src64=` tokens are checked, since their base64 can hold a
  # segment that reads like a marker.
  defp redact_path(path) do
    segments = path |> String.split("/") |> redact_segment_list()

    case split_source(segments, []) do
      {options, marker, tail} -> Enum.join(options ++ [marker, redact_source(marker, tail)], "/")
      :none -> Enum.join(segments, "/")
    end
  end

  # The first marker segment that follows another segment and has a tail.
  defp split_source([segment, marker | [_ | _] = tail], options) when marker in @source_markers,
    do: {Enum.reverse([segment | options]), marker, tail}

  defp split_source([segment | rest], options), do: split_source(rest, [segment | options])
  defp split_source([], _options), do: :none

  # The tail can hold another source, from a request sent under another
  # prefix or a `src` URL whose path has a marker segment, so it's also read
  # as each later source would read it. A later `src64` source hides
  # everything after it, since checking each later token on its own would
  # take time in proportion to the square of the path's length.
  defp redact_source("src64", [token | rest] = tail) do
    if base64_presigned?(Enum.join(tail, "/")) or presigned_segments(token, rest) != nil,
      do: "REDACTED",
      else: redact_later_sources(tail)
  end

  defp redact_source("src", tail) do
    {url, later} = split_at_marker(tail, "src64", [])
    Enum.join([redact_src(Enum.join(url, "/")) | later_src64(later)], "/")
  end

  defp redact_source("enc", tail), do: redact_later_sources(tail)

  defp redact_later_sources(tail) do
    {segments, later} = split_at_marker(tail, "src64", [])

    segments =
      case split_at_marker(segments, "src", []) do
        {before, ["src" | url]} -> before ++ ["src", redact_src(Enum.join(url, "/"))]
        {before, []} -> before
      end

    Enum.join(segments ++ later_src64(later), "/")
  end

  # The segments before the first `marker` segment that has a tail, and that
  # marker with its tail.
  defp split_at_marker([marker, _ | _] = later, marker, before),
    do: {Enum.reverse(before), later}

  defp split_at_marker([segment | rest], marker, before),
    do: split_at_marker(rest, marker, [segment | before])

  defp split_at_marker([], _marker, before), do: {Enum.reverse(before), []}

  defp later_src64([]), do: []
  defp later_src64(["src64" | _tail]), do: ["src64", "REDACTED"]

  # Standard base64 can hold `/`, so a `wm-src64=` token is also tried joined
  # with the base64-looking segments after it, as many as a request can hold.
  @max_joined_segments 64

  defp redact_segment_list(["wm-src64=" <> token = segment | rest]) do
    case presigned_segments(token, rest) do
      nil -> [segment | redact_segment_list(rest)]
      taken -> ["wm-src64=REDACTED" | redact_segment_list(Enum.drop(rest, taken))]
    end
  end

  defp redact_segment_list([segment | rest]), do: [segment | redact_segment_list(rest)]
  defp redact_segment_list([]), do: []

  # How many segments after `token` a presigned base64 URL takes, or nil.
  defp presigned_segments(token, rest),
    do: if(base64_presigned?(token), do: 0, else: joined_presigned(token, rest))

  # The fewest following segments that make the token a presigned URL, or
  # nil. A joined candidate holds a `/`, so only standard base64 can decode
  # it, as sent or percent-decoded. While a spelling's segments are all
  # standard base64 characters, each candidate decodes to a prefix of one
  # stream, and a prefix is presigned once it reaches the end of the stream's
  # first credential name. So the stream is decoded once per spelling, and
  # only a candidate whose last segment holds another character is decoded
  # on its own, at most once per spelling.
  defp joined_presigned(token, rest) do
    case base64_run(token, rest, 0) do
      [] ->
        nil

      pieces ->
        segments = [token | pieces]

        verdicts =
          [segments, Enum.map(segments, &URI.decode/1)]
          |> Enum.uniq()
          |> Enum.map(&joined_verdicts/1)

        first_presigned(segments, verdicts, 1)
    end
  end

  defp base64_run(previous, [segment | rest], count) when count < @max_joined_segments do
    if base64_open?(previous) and base64_piece?(segment),
      do: [segment | base64_run(segment, rest, count + 1)],
      else: []
  end

  defp base64_run(_previous, _segments, _count), do: []

  # For each candidate from one following segment on: `true` when it's
  # presigned, `:decode` when only decoding it can tell. A segment with a
  # character outside standard base64 leaves every longer candidate invalid.
  defp joined_verdicts([first | rest]) do
    if base64_alphabet?(first) do
      {pure, other} = Enum.split_while(rest, &base64_alphabet?/1)
      reach = pure_stream_reach([first | pure])
      verdicts = pure_verdicts(pure, byte_size(first), trailing_slashes(first), reach)
      if other == [], do: verdicts, else: verdicts ++ [:decode]
    else
      []
    end
  end

  # The decoded length a candidate needs to be presigned: the end of the
  # first credential name in the whole stream, or nil. A credential whose
  # value is already `REDACTED` counts too, which can only redact more.
  defp pure_stream_reach(segments) do
    chars = Enum.join(segments, "/")
    {:ok, url} = Base.decode64(binary_part(chars, 0, div(byte_size(chars), 4) * 4))
    presigned_reach(url)
  end

  # Each candidate is tried as sent and with its trailing slashes trimmed.
  defp pure_verdicts([segment | rest], length, slashes, reach) do
    length = length + 1 + byte_size(segment)

    slashes =
      if trailing_slashes(segment) == byte_size(segment),
        do: slashes + 1 + byte_size(segment),
        else: trailing_slashes(segment)

    presigned =
      reach != nil and
        (decodes_past?(length, reach) or (slashes > 0 and decodes_past?(length - slashes, reach)))

    [presigned | pure_verdicts(rest, length, slashes, reach)]
  end

  defp pure_verdicts([], _length, _slashes, _reach), do: []

  defp decodes_past?(length, reach), do: rem(length, 4) == 0 and div(length, 4) * 3 >= reach

  defp first_presigned(segments, verdicts, taken) do
    heads = for [head | _tail] <- verdicts, do: head

    cond do
      heads == [] -> nil
      true in heads -> taken
      :decode in heads and joined_presigned?(segments, taken) -> taken
      true -> first_presigned(segments, for([_head | tail] <- verdicts, do: tail), taken + 1)
    end
  end

  # A joined candidate's `/` leaves only standard base64. Trimming its
  # trailing slashes back to the token alone gives a spelling already tried.
  defp joined_presigned?(segments, taken),
    do: segments |> Enum.take(taken + 1) |> Enum.join("/") |> base64_presigned?([:standard])

  defp trailing_slashes(segment),
    do: byte_size(segment) - byte_size(String.trim_trailing(segment, "/"))

  # A segment that a later one could continue: base64 without padding or an
  # extension. `%` allows a percent-escaped `+` or `=` beside a literal `/`.
  defp base64_open?(segment), do: segment != "" and base64_chars?(segment, "")

  # A segment that can continue a base64 token, possibly ending it.
  defp base64_piece?(segment), do: segment != "" and base64_chars?(segment, "=.")

  defp base64_chars?(<<char, rest::binary>>, extra)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?+, ?%],
       do: base64_chars?(rest, extra)

  defp base64_chars?(<<char, rest::binary>>, extra) do
    :binary.match(extra, <<char>>) != :nomatch and base64_chars?(rest, extra)
  end

  defp base64_chars?(<<>>, _extra), do: true

  defp base64_alphabet?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9 or char in [?+, ?/],
       do: base64_alphabet?(rest)

  defp base64_alphabet?(<<>>), do: true
  defp base64_alphabet?(_other), do: false

  # A later source reads its query from the first `?` after its marker, so
  # a name after any `?` in the query is a parameter name too. The request's
  # query string is read the same way, since an unescaped `?` in a later
  # source starts it.
  defp redact_src(tail) do
    with [base, query] <- String.split(String.replace_invalid(URI.decode(tail)), "?", parts: 2),
         redacted when redacted != query <- redact_params(query, &redact_src_param/1) do
      base <> "?" <> redacted
    else
      _as_sent -> tail
    end
  end

  # The pair up to the `=` after the first credential name, then
  # `REDACTED`. A name starts the pair or follows a `?`. A name holding a
  # `?` is never a credential one, so each `=` has one candidate name.
  defp redact_src_param(pair) do
    pieces = String.split(pair, "=")

    case pieces |> Enum.drop(-1) |> Enum.with_index() |> Enum.find(&src_param_name?/1) do
      {_name, index} -> Enum.join(Enum.take(pieces, index + 1), "=") <> "=REDACTED"
      nil -> pair
    end
  end

  defp src_param_name?({piece, index}) do
    case :binary.matches(piece, "?") do
      [] ->
        index == 0 and credential_param?(piece)

      matches ->
        {position, 1} = List.last(matches)
        credential_param?(binary_part(piece, position + 1, byte_size(piece) - position - 1))
    end
  end

  # Every spelling a base64 source might use, valid or not, since a request
  # the parser rejects is logged too.
  @base64_decoders [:url_unpadded, :url, :standard]

  defp base64_presigned?(token, decoders \\ @base64_decoders) do
    Enum.any?(base64_spellings(token), fn candidate ->
      Enum.any?(decoders, &presigned_decoding?(&1, candidate))
    end)
  end

  defp base64_spellings(token) do
    for spelling <- Enum.uniq([token, URI.decode(token)]),
        spelling <- Enum.uniq([spelling, String.trim_trailing(spelling, "/")]),
        spelling <- Enum.uniq([spelling, strip_extension(spelling)]),
        uniq: true,
        do: spelling
  end

  defp presigned_decoding?(decoder, candidate) do
    case decode64(decoder, candidate) do
      {:ok, url} -> presigned_url?(url)
      :error -> false
    end
  end

  defp decode64(:url_unpadded, candidate), do: Base.url_decode64(candidate, padding: false)
  defp decode64(:url, candidate), do: Base.url_decode64(candidate)
  defp decode64(:standard, candidate), do: Base.decode64(candidate)

  defp strip_extension(token) do
    with [_ | _] = dots <- :binary.matches(token, "."),
         {position, 1} = List.last(dots),
         extension = binary_part(token, position + 1, byte_size(token) - position - 1),
         true <- extension != "" and alphanumeric?(extension) do
      binary_part(token, 0, position)
    else
      _no_extension -> token
    end
  end

  defp alphanumeric?(<<char, rest::binary>>)
       when char in ?A..?Z or char in ?a..?z or char in ?0..?9,
       do: alphanumeric?(rest)

  defp alphanumeric?(<<>>), do: true
  defp alphanumeric?(_other), do: false

  defp presigned_url?(url) do
    case String.split(url, "?", parts: 2) do
      [_base, query] -> redact_params(query) != query
      [_base] -> false
    end
  end

  # How many bytes of `url` a prefix must hold to be presigned: up to the
  # `=` after the first credential name in its query, or nil.
  defp presigned_reach(url) do
    case :binary.match(url, "?") do
      {position, 1} -> credential_reach(url, position + 1)
      :nomatch -> nil
    end
  end

  defp credential_reach(url, start) do
    size = byte_size(url)

    {pair_end, next} =
      case :binary.match(url, ["&", ";"], scope: {start, size - start}) do
        {position, 1} -> {position, position + 1}
        :nomatch -> {size, nil}
      end

    with {equals, 1} <- :binary.match(url, "=", scope: {start, pair_end - start}),
         true <- credential_param?(binary_part(url, start, equals - start)) do
      equals + 1
    else
      _not_credential -> if next, do: credential_reach(url, next)
    end
  end

  # Parameters are split on `&` and `;`. A name matches in any case and
  # percent-encoding, as an origin reads it.
  defp redact_params(query, redact_param \\ &redact_param/1),
    do: query |> redact_params(redact_param, []) |> IO.iodata_to_binary()

  defp redact_params(query, redact_param, acc) do
    case :binary.match(query, ["&", ";"]) do
      {position, 1} ->
        pair = binary_part(query, 0, position)
        separator = binary_part(query, position, 1)
        rest = binary_part(query, position + 1, byte_size(query) - position - 1)
        redact_params(rest, redact_param, [acc, redact_param.(pair), separator])

      :nomatch ->
        [acc, redact_param.(query)]
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
