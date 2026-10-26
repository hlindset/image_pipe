defmodule ImagePipe.Processing do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [DebugBuilder, Terminal]

  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Format
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Output.Skipped
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Processing.DebugBuilder
  alias ImagePipe.Processing.Prepared
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Clamp
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  def prepare(%Spec{} = request, config, accept) do
    with :ok <- check_expires(request, Keyword.fetch!(config, :clock).()),
         {:ok, policy} <- Policy.from_request(request.output, config, accept),
         :ok <- Policy.ensure_capable(policy),
         :ok <- check_detector(request, config) do
      {:ok, image_policy(request.output.terminal, policy, request, config)}
    end
  end

  # Placeholders and info validate the image options like an image request,
  # then ignore them.
  defp image_policy(terminal, _policy, _request, _config)
       when terminal in [:blurhash, :lqip_css, :info],
       do: nil

  defp image_policy(_terminal, policy, request, config),
    do: skip_formats(policy, request, config)

  # A watermark protects the image, so a request that draws one is never
  # delivered unprocessed.
  defp skip_formats(policy, %Spec{groups: groups}, config) do
    formats =
      case Enum.any?(groups, &(&1.watermark != nil)) do
        true -> []
        false -> Keyword.fetch!(config, :skip_processing_formats)
      end

    Policy.put_skip_formats(policy, formats)
  end

  defp check_expires(%Spec{expires: nil}, _now), do: :ok
  defp check_expires(%Spec{expires: expires}, now) when expires < now, do: {:error, :expired}
  defp check_expires(%Spec{}, _now), do: :ok

  defp check_detector(request, config) do
    detector = Keyword.fetch!(config, :detector)

    with :ok <- check_known_classes(request, detector) do
      case {explicit_detector_classes(request), Keyword.fetch!(config, :detector_required)} do
        {nil, _required?} -> :ok
        {_classes, false} -> :ok
        {classes, true} -> check_required(detector, classes: classes)
      end
    end
  end

  # Weighted names count too: `detect=all,unicorn:3` names `unicorn`.
  defp check_known_classes(%Spec{groups: groups}, detector) do
    named =
      for %{guide: {:detect, {requested, weights}}} <- groups,
          name <- List.wrap(requested) ++ Map.keys(weights),
          is_binary(name),
          uniq: true,
          do: name

    case {named, detector} do
      {[], _detector} ->
        :ok

      {_named, nil} ->
        :ok

      {named, detector} ->
        case named -- detector.supported_classes([]) do
          [] -> :ok
          unknown -> {:error, {:detector, {:unknown_classes, Enum.sort(unknown)}}}
        end
    end
  end

  defp check_required(detector, opts) do
    cond do
      not Transform.detector_available?(detector, opts) -> {:error, {:detector, :unavailable}}
      not Transform.detector_ready?(detector, opts) -> {:error, {:detector, :not_ready}}
      true -> :ok
    end
  end

  def explicit_detector_classes(%Spec{groups: groups}) do
    groups
    |> Enum.reduce_while([], fn group, classes ->
      case group.guide do
        {:detect, {:all, _weights}} -> {:halt, :all}
        {:detect, {requested, _weights}} -> {:cont, requested ++ classes}
        _other -> {:cont, classes}
      end
    end)
    |> case do
      :all -> :all
      [] -> nil
      classes -> classes |> Enum.uniq() |> Enum.sort()
    end
  end

  def resume_fun({:ok, prepared}, bytes, config), do: build_prepared(prepared, bytes, config)

  def prepare_download(request, source, policy, config) do
    started = System.monotonic_time(:microsecond)

    Decode.with_image(
      source,
      request,
      config,
      fn state, geometry ->
        decode_us = System.monotonic_time(:microsecond) - started
        # The source closes when this callback returns, before the encode.
        prepare_pixels(state, geometry, request, policy, config, %{}, decode_us, false)
      end,
      {policy.skip_formats, fn _format, _chunks -> {:ok, :skipped} end}
    )
  end

  defp build_prepared(prepared, bytes, config) do
    geometry = prepared.geometry
    geometry = %{geometry | debug_facts: Map.put(geometry.debug_facts, :source_bytes, bytes)}
    prepared = %{prepared | geometry: geometry}

    fn pump ->
      try do
        produce_prepared(prepared, config, pump)
      after
        Keyword.get(config, :on_bracket_exit, fn -> :ok end).()
      end
    end
  end

  # `watermark_inputs` are the request's watermark asset bytes, or the
  # deferred reads that produce them (see with_watermarks/2).
  def build_fun(%Spec{} = request, source, policy, config, watermark_inputs) do
    fn pump ->
      started = System.monotonic_time(:microsecond)

      with_watermarks(
        watermark_inputs,
        &produce_decoded(source, request, policy, config, &1, pump, started)
      )
    end
  end

  defp produce_decoded(source, request, policy, config, inputs, pump, started) do
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    Decode.with_image(
      source,
      request,
      config,
      fn state, geometry ->
        decode_us = System.monotonic_time(:microsecond) - started

        stream = fn ->
          produce_stream(state, geometry, request, policy, config, inputs, pump, decode_us)
        end

        bracket(stream, on_bracket_exit)
      end,
      {policy.skip_formats,
       fn format, chunks ->
         bracket(fn -> produce_skipped(policy, format, chunks, pump) end, on_bracket_exit)
       end}
    )
  end

  defp produce_skipped(policy, format, chunks, pump),
    do: pump.(chunks, Format.mime_type!(format), Skipped.new(policy, format), nil)

  defp bracket(fun, on_exit) do
    fun.()
  after
    on_exit.()
  end

  defp produce_stream(state, geometry, request, policy, config, inputs, pump, decode_us) do
    with {:ok, prepared} <-
           prepare_pixels(state, geometry, request, policy, config, inputs, decode_us, true) do
      produce_prepared(prepared, config, pump)
    end
  end

  # An overlapped preparation never has watermarks (Execution starts it only
  # without them), so prepare_download/4 passes no inputs.
  # `encode_ahead?` is whether the encode runs while the source is still
  # open, so it may read the source instead of a buffered copy.
  defp prepare_pixels(state, geometry, request, policy, config, inputs, decode_us, encode_ahead?) do
    shrink = state.decode_shrink
    operations = Executor.operation_names(request)

    with {{:ok, %State{} = state}, transform_us} <-
           Timing.measure(fn ->
             run_transform(state, geometry, request, operations, policy, config, inputs)
           end),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(policy, geometry.source_format, state.image, config),
         resolved_output = %ResolvedOutput{resolved_output | degraded?: state.degraded?},
         :ok <- Executor.check_evaluation(state),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             [kernel: Executor.result_kernel(request)] ++ config
           ),
         {:ok, %State{} = state} <-
           materialize_for_delivery(
             %State{state | image: clamped},
             encode_ahead? and Encoder.encode_ahead?(resolved_output)
           ) do
      {:ok,
       %Prepared{
         state: state,
         geometry: geometry,
         resolved_output: resolved_output,
         policy: policy,
         shrink: shrink,
         operations: operations,
         detections: state.detections,
         rotations: Executor.arbitrary_rotations(request),
         timings: %{decode: decode_us, transform: transform_us}
       }}
    else
      {{:error, _reason} = error, _microseconds} -> error
      {:error, _reason} = error -> error
    end
  end

  defp produce_prepared(%Prepared{} = prepared, config, pump) do
    %{state: state, resolved_output: resolved_output} = prepared
    image = state.image

    result =
      Timing.measure(fn ->
        encode_first_chunk(
          image,
          resolved_output,
          {state.source_color_profile, state.color_imported?},
          Keyword.put(config, :encode_ahead, not state.materialized?),
          prepared.geometry.source_check
        )
      end)

    case result do
      {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} ->
        debug = DebugBuilder.build(prepared, search_meta, encode_us)

        pump.({:started, chunk, stream_state}, content_type, resolved_output, debug)

      {:empty, _microseconds} ->
        {:error, {:encode, :empty_stream}}

      {{:error, _reason} = error, _microseconds} ->
        error
    end
  end

  defp run_transform(state, geometry, %Spec{} = request, operations, policy, config, inputs) do
    Telemetry.span(
      config,
      [:transform, :execute],
      %{operations: operations, operation_count: length(operations)},
      fn ->
        result =
          with {:ok, opts} <- watermark_opts(pipeline_opts(policy, geometry, config), inputs) do
            Executor.execute(state, request, opts)
          end

        {result, transform_stop_metadata(result)}
      end
    )
  end

  @doc false
  # Starts deferred watermark reads in this process before the source fetch,
  # cancelling any still running when `fun` returns. `fun` gets the inputs to
  # pass to watermark_opts/2.
  def with_watermarks({:deferred, start}, fun) do
    {await, cancel} = start.()

    try do
      fun.({:started, await})
    after
      cancel.()
    end
  end

  def with_watermarks(inputs, fun), do: fun.(inputs)

  @doc false
  # Decodes the watermark assets execution acquired for this request into
  # `opts`' `:watermark_images`.
  def watermark_opts(opts, inputs) do
    with {:ok, inputs} <- watermark_inputs(inputs) do
      decode_watermarks(inputs, opts)
    end
  end

  defp watermark_inputs({:started, await}), do: await.()
  defp watermark_inputs(inputs), do: {:ok, inputs}

  defp decode_watermarks(inputs, config) do
    inputs
    |> Enum.reduce_while({:ok, %{}}, fn {asset, %{bytes: bytes, opacity: opacity}}, {:ok, acc} ->
      case Decode.watermark(bytes, config) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, asset, Map.put(decoded, :opacity, opacity))}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, images} -> {:ok, Keyword.put(config, :watermark_images, images)}
      error -> error
    end
  end

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Telemetry.error_tag(error)}

  defp pipeline_opts(%Policy{} = policy, geometry, config) do
    Keyword.merge(config,
      supports_hdr?: Policy.supports_hdr?(policy, geometry.source_format),
      srgb_output?: Policy.srgb_output?(policy),
      opaque_output?: Policy.opaque_output?(policy)
    )
  end

  defp resolve_output(policy, source_format, image, config) do
    Policy.negotiate(policy, source_format, image, config)
  end

  defp encode_first_chunk(image, resolved_output, source_color, config, source_check) do
    Telemetry.span(
      config,
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, source_color, config)
                 |> classify_encode_ahead(source_check),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  # An encode that read the original fails the same way whether the original
  # or the encoder failed, and libvips' error text isn't reliable under
  # concurrency, so the original is decoded again: a corrupt original fails
  # again (415), and an original that decodes means the encoder failed (500).
  defp classify_encode_ahead({:error, {:encode_ahead, exception}}, source_check) do
    case source_check && source_check.() do
      :ok -> {:error, {:encode, exception, []}}
      {:error, reason} -> {:error, {:decode, reason}}
      nil -> {:error, {:decode, exception}}
    end
  end

  defp classify_encode_ahead(result, _source_check), do: result

  defp first_chunk(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  defp encode_stop_metadata({:ok, _chunk, _ct, _stream_state, _meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Telemetry.error_tag(reason)}

  # An output encoded ahead reads the source while it encodes, before the
  # response starts, so the frame isn't copied first.
  defp materialize_for_delivery(%State{materialized?: true} = state, _encode_ahead?),
    do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, true), do: {:ok, state}
  defp materialize_for_delivery(%State{} = state, false), do: Materializer.materialize(state)

  # The server's result caps, narrowed by the encoder's when the format is known.
  @doc false
  @spec result_limits(atom() | nil, keyword()) :: Clamp.limits()
  def result_limits(format, config) do
    %{max_dimension: encoder_dimension, max_pixels: encoder_pixels} =
      encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(config, :max_result_width), encoder_dimension),
      max_height: min_limit(Keyword.fetch!(config, :max_result_height), encoder_dimension),
      max_pixels: min_limit(Keyword.fetch!(config, :max_result_pixels), encoder_pixels)
    }
  end

  defp encoder_limit(nil), do: %{max_dimension: :infinity, max_pixels: :infinity}
  defp encoder_limit(format), do: Encoder.encoder_limit(format)

  defp min_limit(host_limit, :infinity), do: host_limit
  defp min_limit(host_limit, encoder_limit), do: min(host_limit, encoder_limit)
end
