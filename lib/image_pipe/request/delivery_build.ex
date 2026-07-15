defmodule ImagePipe.Request.DeliveryBuild do
  @moduledoc false

  # The framework's `ImagePipe.Delivery` build_fun: fetch → decode → transform
  # → clamp → encode, run entirely inside the delivery producer process. It
  # hands the encoder's output to `pump`, along with the `%Debug.Info{}` it
  # collected while producing it.

  alias ImagePipe.Debug.Info
  alias ImagePipe.Debug.Timing
  alias ImagePipe.Delivery.StreamPull
  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Plan
  alias ImagePipe.Request.Processor
  alias ImagePipe.Source
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.State

  @enforce_keys [:plan, :resolved_source, :output_policy, :opts]
  defstruct @enforce_keys

  @type t() :: %__MODULE__{
          plan: Plan.t(),
          resolved_source: Source.Resolved.t(),
          output_policy: Policy.t(),
          opts: keyword()
        }

  @spec build_fun(Plan.t(), Source.Resolved.t(), Policy.t(), keyword()) ::
          (ImagePipe.Delivery.Producer.pump() ->
             ImagePipe.Delivery.Producer.pump_result() | {:error, term()})
  def build_fun(%Plan{} = plan, %Source.Resolved{} = resolved_source, %Policy{} = policy, opts) do
    request = %__MODULE__{
      plan: plan,
      resolved_source: resolved_source,
      output_policy: policy,
      opts: opts
    }

    fn pump -> build_and_pump(request, pump) end
  end

  defp build_and_pump(%__MODULE__{} = request, pump) do
    case prepare_stream(request) do
      {:ok, stream, content_type, resolved_output, debug} ->
        pump.(stream, content_type, resolved_output, debug)

      :empty ->
        {:error, {:encode, :empty_stream}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp prepare_stream(%__MODULE__{} = request) do
    with_stream_translation(&prepare_fallback/2, fn ->
      with {{:ok, decoded}, decode_us} <-
             measure_decode(request.plan, request.resolved_source, request.opts),
           {{:ok, %State{} = final_state}, transform_us} <-
             measure_transform(decoded, request),
           {:ok, %Resolved{} = resolved_output} <-
             resolve_output(
               request.output_policy,
               decoded.source_format,
               final_state.image,
               request.opts
             ),
           limits = effective_limits(resolved_output.format, request.opts),
           {:ok, clamped, clamp_info} <-
             Clamp.clamp(final_state.image, limits, request.opts),
           :ok <- emit_clamp_telemetry(clamp_info, resolved_output.format, request.opts),
           {:ok, %State{image: image}} <-
             Processor.materialize_for_delivery(
               %State{final_state | image: clamped},
               request.opts
             ),
           {{:ok, chunk, content_type, stream_state, search_meta}, encode_us} <-
             measure_encode(image, resolved_output, request.opts) do
        debug =
          build_debug(%{
            request: request,
            decoded: decoded,
            resolved_output: resolved_output,
            image: image,
            search_meta: search_meta,
            timings: %{decode: decode_us, transform: transform_us, encode: encode_us}
          })

        {:ok, StreamPull.resume(chunk, stream_state), content_type, resolved_output, debug}
      else
        {:empty, _us} -> :empty
        :empty -> :empty
        {{:error, reason}, _us} -> {:error, reason}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  # Honest forced-encode span. `Encoder.stream_output/3` builds the lazy encoder
  # pipeline; on the lazy (non-search) path `first_chunk/1` pulls the first chunk,
  # forcing libvips to actually encode — the heaviest stage of most requests. On
  # the `:ssim2` quality-search path the encode already happened eagerly inside the
  # search (the delivered bytes are the winning probe's encode), so here
  # `first_chunk/1` only pulls a pre-encoded buffer and this span's duration is
  # dominated by that earlier search, not by work done under it. Both run here, in
  # the producer process, so the span measures real compute (unlike per-op
  # transform spans, which time construction). Parents to the request root (sibling
  # of the delivery-backstop materialize) via the adopted remote-parent frame.
  defp encode_first_chunk(image, %Resolved{} = resolved_output, opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:encode],
      %{output_format: resolved_output.format},
      fn ->
        result =
          with {:ok, stream, content_type, search_meta} <-
                 Encoder.stream_output(image, resolved_output, opts),
               {:ok, chunk, stream_state} <- first_chunk(stream) do
            {:ok, chunk, content_type, stream_state, search_meta}
          end

        {result, encode_stop_metadata(result, resolved_output.format)}
      end
    )
  end

  defp encode_stop_metadata({:ok, _chunk, _content_type, _stream_state, _search_meta}, format),
    do: %{result: :ok, output_format: format}

  defp encode_stop_metadata(:empty, format),
    do: %{result: :processing_error, output_format: format, error: :empty_stream}

  defp encode_stop_metadata({:error, reason}, format),
    do: %{result: :processing_error, output_format: format, error: Error.tag(reason)}

  defp prepare_fallback(:exit, reason), do: {:error, {:producer, {:exit, reason}}}
  defp prepare_fallback(kind, reason), do: {:error, {:producer, {kind, reason}}}

  defp encode_fallback(kind, reason), do: {:error, {:encode, {kind, reason}, []}}

  # Pulling the first chunk is what forces libvips to actually encode, so it
  # happens here, inside the `[:encode]` span and the measured `encode_us` —
  # not later, in the delivery pump, which would leave both measuring only
  # encoder-pipeline construction. `StreamPull.resume/2` then hands `pump` an
  # enumerable that replays it.
  defp first_chunk(stream) do
    with_stream_translation(&encode_fallback/2, fn ->
      StreamPull.first_chunk(stream)
    end)
  end

  # Effective per-axis + pixel result caps: the tighter of the host `max_result_*`
  # config and the chosen encoder's hard limit. The clamp does not care which
  # source won the `min`.
  defp effective_limits(format, opts) do
    %{max_dimension: enc_dim, max_pixels: enc_px} = Encoder.encoder_limit(format)

    %{
      max_width: min_limit(Keyword.fetch!(opts, :max_result_width), enc_dim),
      max_height: min_limit(Keyword.fetch!(opts, :max_result_height), enc_dim),
      max_pixels: min_limit(Keyword.fetch!(opts, :max_result_pixels), enc_px)
    }
  end

  # The host cap (`a`) is always an integer (NimbleOptions `:pos_integer`); only
  # the encoder limit (`b`) can be `:infinity` ("no limit from the encoder").
  defp min_limit(a, :infinity), do: a
  defp min_limit(a, b), do: min(a, b)

  defp emit_clamp_telemetry(nil, _format, _opts), do: :ok

  defp emit_clamp_telemetry(%{} = info, format, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:output, :clamp],
      %{scale: info.scale},
      %{
        format: format,
        source_dimensions: info.source_dimensions,
        dimensions: info.dimensions,
        limits: info.limits
      }
    )

    :ok
  end

  defp measure_decode(plan, resolved_source, opts),
    do:
      Timing.measure(fn ->
        Processor.fetch_decode_validate_source_with_source_format(plan, resolved_source, opts)
      end)

  defp measure_transform(decoded, request),
    do:
      Timing.measure(fn ->
        Processor.process_decoded_source(
          decoded,
          request.plan,
          Keyword.put(
            request.opts,
            :supports_hdr?,
            Policy.supports_hdr?(
              request.output_policy,
              request.plan.output,
              decoded.source_format
            )
          )
        )
      end)

  defp measure_encode(image, resolved_output, opts),
    do: Timing.measure(fn -> encode_first_chunk(image, resolved_output, opts) end)

  defp build_debug(ctx) do
    %{
      request: request,
      decoded: decoded,
      resolved_output: resolved_output,
      image: image,
      search_meta: search_meta,
      timings: timings
    } = ctx

    %Info{
      source_format: decoded.source_format,
      source_bytes: Map.get(decoded, :source_bytes),
      source_width: dim(decoded, 0),
      source_height: dim(decoded, 1),
      source_color_space: Map.get(decoded, :source_color_space),
      source_icc?: Map.get(decoded, :source_icc?),
      source_bit_depth: Map.get(decoded, :source_bit_depth),
      source_alpha?: Map.get(decoded, :source_alpha?),
      source_orientation: Map.get(decoded, :source_orientation),
      shrink: Map.get(decoded, :achieved_shrink),
      output_format: resolved_output.format,
      output_negotiated?: negotiated?(request.output_policy),
      output_width: Image.width(image),
      output_height: Image.height(image),
      output_quality: output_quality(resolved_output, search_meta),
      output_stripped?: resolved_output.strip_metadata,
      output_color_profile: resolved_output.color_profile,
      output_distance: output_distance(resolved_output, search_meta),
      aq: aq_from_meta(resolved_output, search_meta),
      pipeline: pipeline_names(request.plan),
      timings: timings
    }
  end

  defp dim(decoded, index) do
    case Map.get(decoded, :original_dims) do
      {w, _h} when index == 0 -> w
      {_w, h} when index == 1 -> h
      _ -> nil
    end
  end

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%Resolved{}, %{quality: q}) when is_integer(q) and q > 0, do: q
  defp output_quality(%Resolved{quality: {:quality, q}}, _meta), do: q
  defp output_quality(%Resolved{quality: :default}, _meta), do: :default

  defp output_distance(%Resolved{quality_search: quality_search}, _meta) do
    case quality_search do
      :none ->
        nil

      %module{target: target} when is_number(target) ->
        if native_jxl_search?(module), do: target, else: nil

      _ ->
        nil
    end
  end

  defp aq_from_meta(_resolved_output, nil), do: nil
  defp aq_from_meta(%Resolved{quality_search: :none}, _meta), do: nil

  defp aq_from_meta(%Resolved{quality_search: %module{} = rqs}, %{} = meta) do
    %{
      metric: quality_search_metric(module),
      score: if(native_jxl_search?(module), do: nil, else: Map.get(meta, :score)),
      target: Map.get(rqs, :target),
      min: Map.get(rqs, :min_quality),
      max: Map.get(rqs, :max_quality),
      iterations: Map.get(meta, :iterations),
      outcome: Map.get(meta, :outcome),
      limiting_factor: Map.get(meta, :limiting_factor),
      scorer: Map.get(meta, :scorer),
      tiles: Map.get(meta, :tiles_scored)
    }
  end

  defp quality_search_metric(module) do
    case module |> Module.split() |> List.last() do
      "Ssimulacra2" -> :ssimulacra2
      "Butteraugli" -> :butteraugli
      "NativeJxlButteraugli" -> :butteraugli
      "Size" -> :size
      _ -> nil
    end
  end

  defp native_jxl_search?(module),
    do: module |> Module.split() |> List.last() == "NativeJxlButteraugli"

  # Pipeline operation names, in order, derived neutrally from the plan's semantic
  # operations (ImagePipe.Plan.Operation.*). We reflect on the struct module's
  # short name rather than naming any concrete module literal (boundary rule) and
  # do NOT use Transform.transform_name/1 (that operates on translated *transform*
  # operations, not the plan's semantic structs).
  defp pipeline_names(plan) do
    plan.pipelines
    |> Enum.flat_map(fn %{operations: ops} -> ops end)
    |> Enum.map(&operation_name/1)
  end

  defp operation_name(%module{}),
    do: module |> Module.split() |> List.last() |> Macro.underscore()

  defp resolve_output(%Policy{} = policy, source_format, image, opts) do
    Telemetry.span(
      Telemetry.telemetry_opts(opts),
      [:output, :negotiate],
      output_negotiate_metadata(policy),
      fn ->
        result = do_resolve_output(policy, source_format, image)
        {result, output_negotiate_stop_metadata(result)}
      end
    )
  end

  defp do_resolve_output(%Policy{} = policy, source_format, image) do
    case Policy.resolve(policy, source_format) do
      {:ok, %Resolved{} = resolved_output} ->
        {:ok, resolved_output}

      {:needs_final_image_alpha, :source} ->
        {:ok, Policy.resolve_final_image_alpha(policy, Image.has_alpha?(image))}

      {:error, reason} ->
        {:error, {:output, reason}}
    end
  end

  defp output_negotiate_metadata(%Policy{} = policy) do
    %{output_mode: output_mode(policy)}
  end

  defp output_mode(%Policy{mode: {:explicit, _format}}), do: :explicit
  defp output_mode(%Policy{mode: :source}), do: :automatic

  defp output_negotiate_stop_metadata({:ok, %Resolved{format: format}}) do
    %{result: :ok, output_format: format}
  end

  defp output_negotiate_stop_metadata({:error, reason}) do
    %{result: :output_error, error: Error.tag(reason)}
  end

  # Single source of truth for StreamError -> tagged-error translation.
  # `fallback` builds the tag for any non-StreamError throw/exit so callers keep
  # their distinct generic tags (prepare uses :producer, the encode pull uses
  # :encode). Once the encoder stream reaches `pump`, `ImagePipe.Delivery.Producer`
  # applies the same rule to the chunk path.
  defp with_stream_translation(fallback, fun) do
    fun.()
  rescue
    exception in [StreamError] -> {:error, {:source, exception.reason}}
    exception -> {:error, {:encode, exception, __STACKTRACE__}}
  catch
    :exit, {%StreamError{reason: reason}, _stacktrace} -> {:error, {:source, reason}}
    :exit, %StreamError{reason: reason} -> {:error, {:source, reason}}
    kind, reason -> fallback.(kind, reason)
  end
end
