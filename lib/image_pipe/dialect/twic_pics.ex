defmodule ImagePipe.Dialect.TwicPics do
  @moduledoc """
  Plug entry point for ImagePipe's TwicPics-compatible URL dialect.

  This dialect owns its request chain end to end. It parses the positional
  TwicPics manipulation, resolves the source and output policy, builds the
  representation identity before cache access, then runs decode, the ordered
  TwicPics pipeline, final output negotiation, clamp, materialization, encode,
  and delivery through ImagePipe's core boundaries.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Config,
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Dialect.SharedConfig,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Cache
  alias ImagePipe.Debug.Info
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Dialect.TwicPics.Config
  alias ImagePipe.Dialect.TwicPics.Errors
  alias ImagePipe.Dialect.TwicPics.Identity
  alias ImagePipe.Dialect.TwicPics.Manipulation
  alias ImagePipe.Dialect.TwicPics.Negotiation
  alias ImagePipe.Dialect.TwicPics.Path
  alias ImagePipe.Dialect.TwicPics.Pipeline
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.RequestBuilder
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Negotiate
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Plan.Operation, as: PlanOperation
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.Conditional
  alias ImagePipe.Response.CORS
  alias ImagePipe.Response.Sender
  alias ImagePipe.Source, as: ImageSource
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @doc false
  @spec parse(Plug.Conn.t(), keyword()) :: {:ok, Request.t()} | {:error, term()}
  def parse(%Plug.Conn{} = conn, config) do
    with {:ok, source, manipulation} <- Path.extract(conn),
         {:ok, chain} <- Manipulation.parse(manipulation) do
      RequestBuilder.build(source, chain, config)
    end
  end

  @impl Plug
  # ex_dna:disable-for-next-line
  def call(%Plug.Conn{} = conn, config) when is_list(config) do
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, config)

    Telemetry.span(Telemetry.telemetry_opts(config), [:request], %{}, fn ->
      {conn, metadata} = route(conn, config)
      {conn, request_stop_metadata(conn, metadata)}
    end)
  end

  defp request_stop_metadata(%Plug.Conn{} = conn, metadata) do
    metadata
    |> Map.put(:result, Map.get(conn.private, :image_pipe_send_result, metadata.result))
    |> Map.put(:status, conn.status)
  end

  # ex_dna:disable-for-next-line
  defp route(%Plug.Conn{method: "OPTIONS"} = conn, config) do
    conn = send_with_span(conn, config, :options, fn -> CORS.send_options(conn, config) end)
    {conn, %{result: :options}}
  end

  # ex_dna:disable-for-next-line
  defp route(%Plug.Conn{method: method} = conn, config) when method not in ["GET", "HEAD"] do
    conn =
      send_with_span(conn, config, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end

  defp route(%Plug.Conn{} = conn, config) do
    case parse_with_span(conn, config) do
      {:ok, %Request{} = request} -> execute(conn, request, config)
      {:error, reason} -> send_parse_error(conn, reason, config)
    end
  end

  defp parse_with_span(%Plug.Conn{} = conn, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:parse], %{}, fn ->
      result = parse(conn, config)
      {result, parse_stop_metadata(result)}
    end)
  end

  # ex_dna:disable-for-next-line
  defp parse_stop_metadata({:ok, %Request{}}), do: %{result: :ok}

  defp parse_stop_metadata({:error, reason}),
    do: %{result: :error, error: Error.tag(reason)}

  defp execute(conn, %Request{} = request, config) do
    with {:ok, resolved} <- ImageSource.resolve(request.source, config, config),
         {:ok, negotiation} <- Negotiation.negotiate(conn, request, config) do
      detector_identity = detector_identity(request, config)

      representation =
        Representation.build(
          resolved.identity,
          Identity.material(request, negotiation, conn, config, detector_identity),
          resolved.cache_semantics.byte_identity
        )

      case Conditional.not_modified?(conn, representation.etag) do
        true -> send_not_modified(conn, representation, config)
        false -> serve(conn, request, resolved, negotiation, representation, config)
      end
    else
      {:error, reason} -> send_error(conn, reason, config)
    end
  end

  defp send_parse_error(conn, reason, config) do
    metadata = %{result: :parser_error, error: Error.tag(reason)}

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Errors.send_parse(conn, reason, config)
      end)

    {conn, metadata}
  end

  defp send_not_modified(conn, %Representation{} = representation, config) do
    conn =
      send_with_span(conn, config, :not_modified, fn ->
        Sender.send_result(
          conn,
          {:not_modified, CacheHeaders.from_representation(representation)},
          config
        )
      end)

    {conn, %{result: :not_modified}}
  end

  defp send_error(conn, reason, config, headers \\ []) do
    metadata = %{
      result: Telemetry.request_result({:error, reason}),
      error: Error.tag(reason)
    }

    conn =
      send_with_span(conn, config, metadata.result, fn ->
        Errors.send(conn, reason, config, headers)
      end)

    {conn, metadata}
  end

  defp send_with_span(%Plug.Conn{}, config, result, fun) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:send], %{result: result}, fn ->
      sent_conn = fun.()

      {sent_conn,
       %{
         result: Map.get(sent_conn.private, :image_pipe_send_result, result),
         status: sent_conn.status
       }}
    end)
  end

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

  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :disabled} = resolved,
         negotiation,
         representation,
         config
       ) do
    generate(conn, request, resolved, negotiation, representation, nil, config)
  end

  defp serve(
         conn,
         request,
         %ImageSource.Resolved{internal_cache: :enabled} = resolved,
         negotiation,
         representation,
         config
       ) do
    started_at = System.monotonic_time(:microsecond)
    lookup_result = Cache.lookup_entry(representation.cache_key, config)
    cache_serve_us = System.monotonic_time(:microsecond) - started_at

    case lookup_result do
      {:hit, %Cache.Entry{} = entry} ->
        deliver_hit(conn, request, entry, representation, cache_serve_us, config)

      _miss_or_disabled ->
        generate(
          conn,
          request,
          resolved,
          negotiation,
          representation,
          representation.cache_key,
          config
        )
    end
  end

  defp deliver_hit(
         conn,
         %Request{} = request,
         %Cache.Entry{} = entry,
         %Representation{} = representation,
         cache_serve_us,
         config
       ) do
    case Conditional.if_none_match_wildcard?(conn) do
      true ->
        send_not_modified(conn, representation, config)

      false ->
        delivery_config = delivery_config(request, config)

        hit_debug = %{
          cache_key: representation.cache_key.hash,
          cache_serve_us: cache_serve_us
        }

        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:cache_entry, entry, request.response,
                CacheHeaders.from_representation(representation), hit_debug}},
              delivery_config
            )
          end)

        {conn, %{result: :ok}}
    end
  end

  defp generate(
         conn,
         %Request{} = request,
         %ImageSource.Resolved{} = resolved,
         %Negotiation{} = negotiation,
         %Representation{} = representation,
         cache_key,
         config
       ) do
    build_fun = build_fun(resolved, request, negotiation, config)
    delivery_config = delivery_config(request, config)

    case Delivery.stream(self(), build_fun, cache_key, request.response, delivery_config) do
      {:ok, prepared} ->
        conn =
          send_with_span(conn, config, :ok, fn ->
            Sender.send_result(
              conn,
              {:ok,
               {:prepared_stream, prepared, request.response,
                CacheHeaders.from_representation(representation)}},
              delivery_config
            )
          end)

        {conn, %{result: :ok}}

      {:error, reason} ->
        send_error(conn, reason, config, negotiation.policy.headers)
    end
  end

  defp build_fun(
         %ImageSource.Resolved{} = resolved,
         %Request{} = request,
         %Negotiation{} = negotiation,
         config
       ) do
    decode_opts = Keyword.put(config, :auto_rotate?, request.auto_rotate)
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      decode_started_at = System.monotonic_time(:microsecond)

      Decode.with_image(
        resolved,
        decode_opts,
        &Pipeline.decode_request(request, &1),
        fn state, geometry ->
          decode_us = System.monotonic_time(:microsecond) - decode_started_at

          try do
            build_and_pump(
              state,
              geometry,
              request,
              negotiation,
              config,
              pump,
              decode_us
            )
          after
            on_bracket_exit.()
          end
        end
      )
    end
  end

  defp build_and_pump(state, geometry, request, negotiation, config, pump, decode_us) do
    shrink = state.decode_shrink

    with {{:ok, %State{} = state}, transform_us} <-
           Timing.measure(fn ->
             run_transform(state, geometry, request, negotiation, config)
           end),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(negotiation.policy, geometry.source_format, state.image, config),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             config
           ),
         {:ok, %State{image: image}} <-
           materialize_for_delivery(%State{state | image: clamped}, config),
         {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} <-
           Timing.measure(fn -> encode_first_chunk(image, resolved_output, config) end) do
      debug =
        build_debug(
          geometry,
          shrink,
          request,
          negotiation,
          resolved_output,
          image,
          search_meta,
          %{decode: decode_us, transform: transform_us, encode: encode_us}
        )

      pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, debug)
    else
      {:empty, _microseconds} -> {:error, {:encode, :empty_stream}}
      {{:error, _reason} = error, _microseconds} -> error
      {:error, _reason} = error -> error
    end
  end

  defp run_transform(state, geometry, %Request{} = request, negotiation, config) do
    operations = operation_names(request)

    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: operations, operation_count: length(operations)},
      fn ->
        result =
          safe_transform(fn ->
            Pipeline.run(
              state,
              geometry,
              request,
              pipeline_opts(negotiation, request, geometry, config)
            )
          end)

        {result, transform_stop_metadata(result)}
      end
    )
  end

  defp safe_transform(fun) do
    fun.()
  rescue
    exception -> {:error, {:transform, {exception, __STACKTRACE__}}}
  catch
    kind, reason -> {:error, {:transform, {kind, reason}}}
  end

  # ex_dna:disable-for-next-line
  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, reason}),
    do: %{result: :processing_error, error: Error.tag(reason)}

  # ex_dna:disable-for-next-line
  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, config),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  # ex_dna:disable-for-next-line
  defp encode_stop_metadata(
         {:ok, _chunk, _content_type, _stream_state, _search_meta},
         format
       ),
       do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  # ex_dna:disable-for-next-line
  defp first_chunk(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  # ex_dna:disable-for-next-line
  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    case Materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

  defp pipeline_opts(%Negotiation{policy: policy}, %Request{} = request, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(policy, request.output, geometry.source_format)
    )
  end

  # ex_dna:disable-for-next-line
  defp resolve_output(policy, source_format, image, config) do
    Negotiate.negotiate_output(
      policy,
      source_format,
      fn -> Image.has_alpha?(image) end,
      Telemetry.telemetry_opts(config)
    )
  end

  # ex_dna:disable-for-next-line
  defp result_limits(format, config) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
      max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
      max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
    }
  end

  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)

  defp delivery_config(%Request{} = request, config) do
    debug? = request.response.debug? and Keyword.fetch!(config, :allow_debug_headers)
    Keyword.put(config, :debug?, debug?)
  end

  defp build_debug(
         geometry,
         shrink,
         request,
         negotiation,
         resolved_output,
         image,
         search_meta,
         timings
       ) do
    {source_width, source_height} = geometry.storage_dimensions

    %Info{
      source_format: geometry.source_format,
      source_width: source_width,
      source_height: source_height,
      shrink: shrink,
      output_format: resolved_output.format,
      output_negotiated?: negotiated?(negotiation.policy),
      output_width: Image.width(image),
      output_height: Image.height(image),
      output_quality: output_quality(resolved_output, search_meta),
      output_stripped?: resolved_output.strip_metadata,
      output_color_profile: resolved_output.color_profile,
      output_distance: output_distance(resolved_output),
      aq: aq_from_meta(resolved_output, search_meta),
      pipeline: operation_names(request),
      timings: timings
    }
  end

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%ResolvedOutput{}, %{quality: quality})
       when is_integer(quality) and quality > 0,
       do: quality

  defp output_quality(%ResolvedOutput{quality: {:quality, quality}}, _search_meta), do: quality
  defp output_quality(%ResolvedOutput{quality: :default}, _search_meta), do: :default

  defp output_distance(%ResolvedOutput{quality_search: :none}), do: nil

  defp output_distance(%ResolvedOutput{quality_search: %module{target: target}})
       when is_number(target) do
    case native_jxl_search?(module) do
      true -> target
      false -> nil
    end
  end

  defp output_distance(%ResolvedOutput{}), do: nil

  defp aq_from_meta(_resolved_output, nil), do: nil
  defp aq_from_meta(%ResolvedOutput{quality_search: :none}, _search_meta), do: nil

  defp aq_from_meta(%ResolvedOutput{quality_search: %module{} = search}, %{} = metadata) do
    metric = quality_search_metric(module)

    %{
      metric: metric,
      score: quality_search_score(module, metadata),
      target: Map.get(search, :target),
      min: Map.get(search, :min_quality),
      max: Map.get(search, :max_quality),
      iterations: Map.get(metadata, :iterations),
      outcome: Map.get(metadata, :outcome),
      limiting_factor: Map.get(metadata, :limiting_factor),
      scorer: Map.get(metadata, :scorer),
      tiles: Map.get(metadata, :tiles_scored)
    }
  end

  defp quality_search_score(module, metadata) do
    case native_jxl_search?(module) do
      true -> nil
      false -> Map.get(metadata, :score)
    end
  end

  defp quality_search_metric(module) do
    case module |> Module.split() |> List.last() do
      "Ssimulacra2" -> :ssimulacra2
      "Butteraugli" -> :butteraugli
      "NativeJxlButteraugli" -> :butteraugli
      "Size" -> :size
      _other -> nil
    end
  end

  defp native_jxl_search?(module),
    do: module |> Module.split() |> List.last() == "NativeJxlButteraugli"

  defp operation_names(%Request{steps: steps}) do
    for {kind, operation} <- steps,
        kind in [:operation, :focused],
        do: PlanOperation.name(operation)
  end
end
