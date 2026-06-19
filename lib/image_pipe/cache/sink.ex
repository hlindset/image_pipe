defmodule ImagePipe.Cache.Sink do
  @moduledoc false

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Error
  alias ImagePipe.Format
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry

  @enforce_keys [
    :adapter,
    :key,
    :adapter_opts,
    :metadata,
    :state,
    :size,
    :max_body_bytes,
    :output_format
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          adapter: module(),
          key: Key.t(),
          adapter_opts: keyword(),
          metadata: Entry.Metadata.t(),
          state: term(),
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          output_format: atom()
        }

  @spec open(module(), Key.t(), Resolved.t(), keyword(), keyword()) :: t() | nil
  def open(adapter, %Key{} = key, %Resolved{} = resolved_output, cache_opts, opts) do
    cost_us = Keyword.get(opts, :cost_us, 0)

    with {:ok, metadata} <- response_metadata(resolved_output, cost_us),
         {:ok, adapter_state} <- open_adapter_sink(adapter, key, metadata, cache_opts) do
      build(adapter, key, metadata, cache_opts, adapter_state)
    else
      {:error, reason} ->
        handle_open_error(reason, resolved_output.format, opts)
        nil
    end
  end

  @spec write_chunk(t() | nil, binary(), keyword()) :: t() | nil
  def write_chunk(nil, _chunk, _opts), do: nil

  def write_chunk(%__MODULE__{} = sink, chunk, opts) when is_binary(chunk) do
    case write_chunk_result(sink, chunk, opts) do
      {:ok, sink} -> sink
      {:skip, :too_large} -> nil
      {:error, _reason} -> nil
    end
  end

  @spec commit(t() | nil, keyword()) :: :ok
  def commit(nil, _opts), do: :ok

  def commit(%__MODULE__{} = sink, opts) do
    # Cache commit errors are logged and emitted as telemetry; streamed
    # responses stay fail-open once bytes have already been sent.
    emit_commit_result(sink, opts)
    :ok
  end

  @spec abort(t() | nil, atom(), keyword()) :: :ok
  def abort(nil, _reason, _opts), do: :ok

  def abort(%__MODULE__{} = sink, reason, opts) do
    case abort_adapter(sink, opts) do
      :ok ->
        emit_stage_event(:stage_abandoned, reason, nil, sink, opts)

      {:error, abort_reason} ->
        emit_stage_event(:stage_cleanup_error, reason, abort_reason, sink, opts)
    end

    :ok
  end

  defp response_metadata(%Resolved{} = resolved_output, cost_us) do
    with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok,
       %Entry.Metadata{
         content_type: Format.mime_type!(resolved_output.format),
         headers: headers,
         created_at: DateTime.utc_now(),
         output_format: resolved_output.format,
         cost_us: cost_us
       }}
    end
  end

  defp open_adapter_sink(adapter, %Key{} = key, %Entry.Metadata{} = metadata, cache_opts) do
    case adapter.open_sink(key, metadata, cache_opts) do
      {:ok, _adapter_state} = ok -> ok
      {:error, _reason} = error -> error
      unexpected -> {:error, {:invalid_adapter_result, unexpected}}
    end
  end

  defp build(adapter, %Key{} = key, %Entry.Metadata{} = metadata, cache_opts, adapter_state) do
    %__MODULE__{
      adapter: adapter,
      key: key,
      adapter_opts: cache_opts,
      metadata: metadata,
      state: adapter_state,
      size: 0,
      max_body_bytes: Keyword.get(cache_opts, :max_body_bytes),
      output_format: metadata.output_format
    }
  end

  defp handle_open_error(reason, output_format, opts) do
    Logger.warning("cache sink open error: #{inspect(reason)}")
    emit_stage_event(:stage_error, :open, reason, output_format, opts)
  end

  defp write_chunk_result(%__MODULE__{} = sink, chunk, opts) do
    size = sink.size + byte_size(chunk)

    case check_size(size, sink.max_body_bytes) do
      :ok ->
        do_write_chunk(%{sink | size: size}, chunk, opts)

      {:error, :too_large} ->
        emit_abort_cleanup(abort_adapter(sink, opts), :too_large, sink, opts)
        emit_stage_event(:stage_skipped, :too_large, nil, sink, opts)
        {:skip, :too_large}
    end
  end

  defp do_write_chunk(%__MODULE__{} = sink, chunk, opts) do
    case sink.adapter.write_chunk(sink.state, chunk, sink.adapter_opts) do
      {:ok, adapter_state} ->
        {:ok, %{sink | state: adapter_state}}

      {:error, reason, adapter_state} ->
        sink = %{sink | state: adapter_state}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_stage_event(:stage_error, :write, reason, sink, opts)
        {:error, reason}

      unexpected ->
        reason = {:invalid_adapter_result, unexpected}
        emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_stage_event(:stage_error, :write, reason, sink, opts)
        {:error, reason}
    end
  rescue
    exception ->
      emit_abort_cleanup(abort_adapter(sink, opts), :write_error, sink, opts)
      Logger.warning("cache sink write error: #{inspect(exception)}")
      emit_stage_event(:stage_error, :write, exception, sink, opts)
      {:error, exception}
  end

  defp emit_commit_result(%__MODULE__{} = sink, opts) do
    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], %{}, fn ->
      result =
        try do
          sink.adapter.commit_sink(sink.state, sink.adapter_opts)
        rescue
          exception -> {:error, exception}
        end

      {:ok, commit_stop_metadata(result, sink)}
    end)
  end

  defp commit_stop_metadata(:ok, %__MODULE__{} = sink),
    do: %{result: :ok, cache: :write, output_format: sink.output_format}

  # The adapter accepted the bytes but its admission policy declined to keep
  # the entry (bounded mode). This is a successful, non-error outcome: nothing
  # was stored, so the request path is unaffected (fail-open). Report it on the
  # write span the same way `:write_error` is reported — commit-level outcomes
  # live on `[:cache, :write]`, not on a separate stage event.
  defp commit_stop_metadata({:ok, :rejected}, %__MODULE__{} = sink),
    do: %{result: :ok, cache: :admission_rejected, output_format: sink.output_format}

  defp commit_stop_metadata({:error, reason}, %__MODULE__{} = sink) do
    Logger.warning("cache sink commit error: #{inspect(reason)}")

    %{
      result: :cache_error,
      cache: :write_error,
      error: Error.tag(reason),
      output_format: sink.output_format
    }
  end

  defp commit_stop_metadata(unexpected, %__MODULE__{} = sink) do
    reason = {:invalid_adapter_result, unexpected}
    Logger.warning("cache sink commit error: #{inspect(reason)}")

    %{
      result: :cache_error,
      cache: :write_error,
      error: Error.tag(reason),
      output_format: sink.output_format
    }
  end

  defp abort_adapter(%__MODULE__{} = sink, _opts) do
    case sink.adapter.abort_sink(sink.state, sink.adapter_opts) do
      :ok = ok -> ok
      {:error, _reason} = error -> error
      unexpected -> {:error, {:invalid_adapter_result, unexpected}}
    end
  rescue
    exception -> {:error, exception}
  end

  defp emit_abort_cleanup(:ok, _reason, _sink, _opts), do: :ok

  defp emit_abort_cleanup({:error, cleanup_reason}, reason, %__MODULE__{} = sink, opts) do
    emit_stage_event(:stage_cleanup_error, reason, cleanup_reason, sink, opts)
  end

  defp emit_stage_event(cache_status, reason, error, %__MODULE__{} = sink, opts) do
    emit_stage_event(cache_status, reason, error, sink.output_format, opts)
  end

  defp emit_stage_event(cache_status, reason, error, output_format, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:cache, :stage],
      %{},
      stage_metadata(cache_status, reason, error, output_format)
    )
  end

  defp stage_metadata(:stage_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :stage_error,
      error: Error.tag(error),
      output_format: output_format
    }

  defp stage_metadata(:stage_cleanup_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :stage_cleanup_error,
      error: Error.tag(error),
      output_format: output_format
    }

  defp stage_metadata(cache_status, reason, _error, output_format),
    do: %{
      result: :ok,
      cache: cache_status,
      reason: reason,
      output_format: output_format
    }

  defp check_size(_size, nil), do: :ok
  defp check_size(size, max_body_bytes) when size <= max_body_bytes, do: :ok
  defp check_size(_size, _max_body_bytes), do: {:error, :too_large}
end
