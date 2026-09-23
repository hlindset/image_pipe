defmodule ImagePipe.Processing do
  @moduledoc false
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Debug,
      ImagePipe.Decode,
      ImagePipe.Delivery,
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: [Config, DebugBuilder, Terminal]

  alias ImagePipe.Debug.Timing
  alias ImagePipe.Decode
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.RequestPolicy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Plan.Request
  alias ImagePipe.Processing.DebugBuilder
  alias ImagePipe.Processing.Prepared
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.Transform.Executor
  alias ImagePipe.Transform.Materializer
  alias ImagePipe.Transform.State

  def prepare(%Request{} = request, config, accept) do
    with :ok <- check_expires(request, Keyword.fetch!(config, :clock).()),
         {:ok, policy} <- RequestPolicy.resolve(request.output, config, accept),
         :ok <- ensure_output_capable(policy, config),
         :ok <- check_detector(request, config) do
      {:ok, policy}
    end
  end

  defp check_expires(%Request{expires: nil}, _now), do: :ok
  defp check_expires(%Request{expires: expires}, now) when expires < now, do: {:error, :expired}
  defp check_expires(%Request{}, _now), do: :ok

  defp ensure_output_capable(nil, _config), do: :ok
  defp ensure_output_capable(policy, config), do: Policy.ensure_capable(policy, config)

  defp check_detector(request, config) do
    case explicit_detector_classes(request) do
      nil ->
        :ok

      classes ->
        if Keyword.get(config, :detector_required, false) and
             not Transform.detector_available?(
               Keyword.get(config, :detector, :default),
               Keyword.put(config, :classes, classes)
             ) do
          {:error, {:detector, :unavailable}}
        else
          :ok
        end
    end
  end

  def explicit_detector_classes(%Request{groups: groups}) do
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

  def build_fun(%Request{} = request, source, policy, config) do
    case Keyword.get(config, :prepared_pixels) do
      nil -> build_from_source(request, source, policy, config)
      {{:ok, prepared}, bytes} -> build_prepared(prepared, bytes, config)
      {{:error, _} = error, _bytes} -> fn _pump -> error end
    end
  end

  def streamable_source?(prefix), do: Decode.streamable_source?(prefix)

  def prepare_download(request, source, policy, config) do
    started = System.monotonic_time(:microsecond)

    Decode.with_image(source, request, config, fn state, geometry ->
      decode_us = System.monotonic_time(:microsecond) - started
      prepare_pixels(state, geometry, request, policy, config, decode_us)
    end)
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

  defp build_from_source(request, source, policy, config) do
    on_bracket_exit = Keyword.get(config, :on_bracket_exit, fn -> :ok end)

    fn pump ->
      decode_started_at = System.monotonic_time(:microsecond)

      Decode.with_image(
        source,
        request,
        config,
        fn state, geometry ->
          decode_us = System.monotonic_time(:microsecond) - decode_started_at

          try do
            produce_stream(
              state,
              geometry,
              request,
              policy,
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

  defp produce_stream(state, geometry, request, policy, config, pump, decode_us) do
    with {:ok, prepared} <- prepare_pixels(state, geometry, request, policy, config, decode_us) do
      produce_prepared(prepared, config, pump)
    end
  end

  defp prepare_pixels(state, geometry, request, policy, config, decode_us) do
    shrink = state.decode_shrink

    with {{:ok, %State{} = state}, transform_us} <-
           Timing.measure(fn ->
             run_transform(state, geometry, request, policy, config)
           end),
         {:ok, %ResolvedOutput{} = resolved_output} <-
           resolve_output(policy, geometry.source_format, state.image, config),
         {:ok, clamped, _clamp_info} <-
           Clamp.clamp_with_telemetry(
             state.image,
             result_limits(resolved_output.format, config),
             resolved_output.format,
             config
           ),
         {:ok, %State{} = state} <-
           materialize_for_delivery(%State{state | image: clamped}, config) do
      {:ok,
       %Prepared{
         state: state,
         geometry: geometry,
         resolved_output: resolved_output,
         policy: policy,
         shrink: shrink,
         operations: Executor.operation_names(request),
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
        encode_first_chunk(image, resolved_output, state.source_color_profile, config)
      end)

    case result do
      {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} ->
        debug =
          DebugBuilder.build(%{
            geometry: prepared.geometry,
            shrink: prepared.shrink,
            policy: prepared.policy,
            resolved_output: resolved_output,
            image: image,
            search_meta: search_meta,
            operations: prepared.operations,
            timings: Map.put(prepared.timings, :encode, encode_us)
          })

        pump.(StreamPull.resume(chunk, stream_state), content_type, resolved_output, debug)

      {:empty, _microseconds} ->
        {:error, {:encode, :empty_stream}}

      {{:error, _reason} = error, _microseconds} ->
        error
    end
  end

  defp run_transform(state, geometry, %Request{} = request, policy, config) do
    operations = Executor.operation_names(request)

    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:transform, :execute],
      %{operations: operations, operation_count: length(operations)},
      fn ->
        result =
          Executor.execute(
            state,
            request,
            pipeline_opts(policy, geometry, config)
          )

        {result, transform_stop_metadata(result)}
      end
    )
  end

  defp transform_stop_metadata({:ok, %State{}}), do: %{result: :ok}

  defp transform_stop_metadata({:error, error}),
    do: %{result: :processing_error, error: Error.tag(error)}

  defp pipeline_opts(%Policy{} = policy, geometry, config) do
    Keyword.put(
      config,
      :supports_hdr?,
      Policy.supports_hdr?(policy, geometry.source_format)
    )
  end

  defp resolve_output(policy, source_format, image, config) do
    Policy.negotiate(
      policy,
      source_format,
      image,
      Telemetry.telemetry_opts(config)
    )
  end

  defp encode_first_chunk(image, %ResolvedOutput{} = resolved_output, source_profile, config) do
    Telemetry.span(
      Telemetry.telemetry_opts(config),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, source_profile, config),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  defp first_chunk(stream) do
    StreamPull.translate(fn -> StreamPull.first_chunk(stream) end)
  end

  defp encode_stop_metadata({:ok, _chunk, _ct, _stream_state, _meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  defp materialize_for_delivery(%State{materialized?: true} = state, _config), do: {:ok, state}

  defp materialize_for_delivery(%State{} = state, config) do
    materializer = Keyword.get(config, :image_materializer, Materializer)

    case materializer.materialize(state, config) do
      {:ok, %State{} = materialized} -> {:ok, materialized}
      {:error, reason} -> {:error, {:decode, reason}}
    end
  end

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
end
