defmodule ImagePipe.Request.SourceSession.Producer do
  @moduledoc false

  alias ImagePipe.Error
  alias ImagePipe.Output.Clamp
  alias ImagePipe.Output.Encoder
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Request.Processor
  alias ImagePipe.Request.SourceSession.Request
  alias ImagePipe.Source.StreamError
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.Trace
  alias ImagePipe.Transform.State

  defstruct [
    :request,
    :stream_state,
    :resolved_output,
    :content_type,
    prepared?: false
  ]

  @type t() :: pid()

  @spec start_link(Request.t(), keyword()) :: {:ok, pid()}
  def start_link(%Request{} = request, opts \\ []) do
    caller_chain = Keyword.get(opts, :caller_chain, Process.get(:"$callers", []))
    trace_context = Keyword.get(opts, :trace_context)

    pid =
      spawn_link(fn ->
        Process.put(:"$callers", caller_chain)
        # Hop B: adopt the request's trace context (passed as data, since the spawned
        # process does not inherit the caller's trace stack) so producer-process spans
        # (source.fetch_decode, transform.execute, …) nest under the request root.
        Trace.Stack.adopt(trace_context)
        loop(%__MODULE__{request: request})
      end)

    {:ok, pid}
  end

  # SourceSession drives the producer with these non-blocking primitives after
  # enforcing single-flight demand. A blocking test client lives in
  # ImagePipe.Test.SourceSession.ProducerClient.
  @spec request_next(pid(), pid()) :: reference()
  def request_next(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:next, receiver, ref})
    ref
  end

  @spec request_halt(pid(), pid()) :: reference()
  def request_halt(pid, receiver) when is_pid(pid) and is_pid(receiver) do
    ref = make_ref()
    send(pid, {:halt, receiver, ref})
    ref
  end

  defp loop(%__MODULE__{} = state) do
    receive do
      {:next, caller, ref} ->
        case next_result(state) do
          {:reply, reply, state} ->
            send(caller, {ref, reply})
            loop(state)

          {:stop, reply} ->
            # Domain failures are terminal protocol replies. After sending one,
            # the producer exits normally; unexpected death is reported by the
            # SourceSession monitor.
            send(caller, {ref, reply})
            exit(:normal)
        end

      {:halt, caller, ref} ->
        reply = halt_stream(state)
        send(caller, {ref, reply})
        exit(:normal)
    end
  end

  defp next_result(%__MODULE__{prepared?: false} = state) do
    case prepare_first_chunk(state) do
      {:ok, chunk, state} ->
        reply =
          {:ok,
           {:first_chunk, chunk, state.content_type, state.resolved_output.response_headers,
            state.resolved_output}}

        {:reply, reply, %{state | prepared?: true}}

      :empty ->
        {:stop, {:error, {:encode, :empty_stream}}}

      {:error, reason} ->
        {:stop, {:error, reason}}
    end
  end

  defp next_result(%__MODULE__{stream_state: nil}) do
    {:stop, {:ok, :done}}
  end

  defp next_result(%__MODULE__{stream_state: {acc, continuation}} = state) do
    case continue_stream(acc, continuation, %{state | stream_state: nil}) do
      {:ok, chunk, state} -> {:reply, {:ok, {:chunk, chunk}}, state}
      :done -> {:stop, {:ok, :done}}
      {:error, reason} -> {:stop, {:error, reason}}
    end
  end

  defp prepare_first_chunk(%__MODULE__{request: %Request{} = request} = state) do
    with_stream_translation(&prepare_fallback/2, fn ->
      with {:ok, decoded} <-
             Processor.fetch_decode_validate_source_with_source_format(
               request.plan,
               request.resolved_source,
               request.opts
             ),
           {:ok, %State{} = final_state} <-
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
             ),
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
           {:ok, chunk, content_type, stream_state, _search_meta} <-
             encode_first_chunk(image, resolved_output, request.opts) do
        {:ok, chunk,
         %{
           state
           | stream_state: stream_state,
             resolved_output: resolved_output,
             content_type: content_type
         }}
      else
        :empty -> :empty
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

  defp first_chunk(stream) do
    with_stream_translation(&encode_fallback/2, fn ->
      reduce_stream(stream)
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

  defp continue_stream(acc, continuation, state) do
    with_stream_translation(&encode_fallback/2, fn ->
      continuation.({:cont, acc})
      |> reduce_result(state)
    end)
  end

  # Single source of truth for StreamError -> tagged-error translation.
  # `fallback` builds the tag for any non-StreamError throw/exit so callers keep
  # their distinct generic tags (prepare uses :producer, chunk paths use :encode).
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

  defp reduce_stream(stream) do
    # The producer owns the raw Enumerable continuation so each demand pulls one
    # encoded chunk without blocking SourceSession's GenServer mailbox.
    result =
      Enumerable.reduce(stream, {:cont, nil}, fn
        chunk, _previous when is_binary(chunk) and byte_size(chunk) > 0 -> {:suspend, chunk}
        _chunk, previous -> {:cont, previous}
      end)

    case result do
      {:suspended, chunk, continuation} when is_binary(chunk) ->
        {:ok, chunk, {chunk, continuation}}

      {:done, _previous} ->
        :empty

      {:halted, _previous} ->
        :empty
    end
  end

  defp reduce_result({:suspended, chunk, continuation}, state) when is_binary(chunk) do
    {:ok, chunk, %{state | stream_state: {chunk, continuation}}}
  end

  defp reduce_result({:done, _previous}, _state), do: :done
  defp reduce_result({:halted, _previous}, _state), do: :done

  defp halt_stream(%__MODULE__{stream_state: nil}), do: :ok

  defp halt_stream(%__MODULE__{stream_state: {acc, continuation}}) do
    continuation.({:halt, acc})
    :ok
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
