defmodule ImagePipe.Cache.Sink do
  @moduledoc false

  require Logger

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.Key
  alias ImagePipe.Error
  alias ImagePipe.Format
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry

  @enforce_keys [
    :key,
    :cache_opts,
    :metadata,
    :state,
    :size,
    :max_body_bytes,
    :output_format
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: Key.t(),
          cache_opts: keyword(),
          metadata: Entry.Metadata.t(),
          state: term(),
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          output_format: atom() | nil
        }

  @spec open(Key.t(), Resolved.t() | {:complete_body, String.t()}, keyword(), keyword()) ::
          t() | nil
  def open(%Key{} = key, %Resolved{} = resolved_output, cache_opts, opts) do
    cost_us = Keyword.get(opts, :cost_us, 0)
    debug = Keyword.get(opts, :debug_info)

    with {:ok, metadata} <- response_metadata(resolved_output, cost_us, debug),
         metadata = %{metadata | source_record: Keyword.get(opts, :source_record)},
         {:ok, state} <- FileSystem.open_sink(key, metadata, cache_opts) do
      build(key, metadata, cache_opts, state)
    else
      {:error, reason} ->
        handle_open_error(reason, key, resolved_output.format, opts)
        nil
    end
  end

  # Complete-body sink: a non-image body (e.g. a BlurHash
  # string) delivered whole, with no encoder output and no `%Resolved{}`.
  # Mirrors the `%Resolved{}` clause above exactly, minus everything that
  # only makes sense for an encoded image (response headers, output format).
  def open(%Key{} = key, {:complete_body, content_type}, cache_opts, opts)
      when is_binary(content_type) do
    cost_us = Keyword.get(opts, :cost_us, 0)
    debug = Keyword.get(opts, :debug_info)

    metadata = %{
      complete_body_metadata(content_type, cost_us, debug)
      | source_record: Keyword.get(opts, :source_record)
    }

    case FileSystem.open_sink(key, metadata, cache_opts) do
      {:ok, state} ->
        build(key, metadata, cache_opts, state)

      {:error, reason} ->
        handle_open_error(reason, key, nil, opts)
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
    :ok = abort_store(sink)
    emit_stage_event(:stage_abandoned, reason, nil, sink, opts)
    :ok
  end

  defp response_metadata(%Resolved{} = resolved_output, cost_us, debug) do
    with {:ok, headers} <- Entry.cacheable_headers(resolved_output.response_headers) do
      {:ok,
       %Entry.Metadata{
         content_type: Format.mime_type!(resolved_output.format),
         headers: headers,
         created_at: DateTime.utc_now(),
         output_format: resolved_output.format,
         representation: {:image, resolved_output.format},
         cost_us: cost_us,
         debug: debug
       }}
    end
  end

  defp complete_body_metadata(content_type, cost_us, debug) do
    %Entry.Metadata{
      content_type: content_type,
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: nil,
      representation: {:complete_body, content_type},
      cost_us: cost_us,
      debug: debug
    }
  end

  defp build(%Key{} = key, %Entry.Metadata{} = metadata, cache_opts, state) do
    %__MODULE__{
      key: key,
      cache_opts: cache_opts,
      metadata: metadata,
      state: state,
      size: 0,
      max_body_bytes: Keyword.get(cache_opts, :max_body_bytes),
      output_format: metadata.output_format
    }
  end

  defp handle_open_error(reason, key, output_format, opts) do
    Logger.warning("cache sink open error: #{inspect(reason)}")
    emit_stage_event(:stage_error, :open, reason, {key, output_format}, opts)
  end

  defp write_chunk_result(%__MODULE__{} = sink, chunk, opts) do
    size = sink.size + byte_size(chunk)

    case check_size(size, sink.max_body_bytes) do
      :ok ->
        do_write_chunk(%{sink | size: size}, chunk, opts)

      {:error, :too_large} ->
        :ok = abort_store(sink)
        emit_stage_event(:stage_skipped, :too_large, nil, sink, opts)
        {:skip, :too_large}
    end
  end

  defp do_write_chunk(%__MODULE__{} = sink, chunk, opts) do
    case FileSystem.write_chunk(sink.state, chunk, sink.cache_opts) do
      {:ok, state} ->
        {:ok, %{sink | state: state}}

      {:error, reason, state} ->
        sink = %{sink | state: state}
        :ok = abort_store(sink)
        Logger.warning("cache sink write error: #{inspect(reason)}")
        emit_stage_event(:stage_error, :write, reason, sink, opts)
        {:error, reason}
    end
  end

  defp emit_commit_result(%__MODULE__{} = sink, opts) do
    start_metadata = %{pool: :output, cache_key: sink.key.hash}

    Telemetry.span(Telemetry.telemetry_opts(opts), [:cache, :write], start_metadata, fn ->
      result = FileSystem.commit_sink(sink.state, sink.cache_opts)
      {:ok, Map.put(commit_stop_metadata(result, sink), :cache_key, sink.key.hash)}
    end)
  end

  defp commit_stop_metadata(:ok, %__MODULE__{} = sink),
    do: %{result: :ok, cache: :write, output_format: sink.output_format}

  # The cache accepted the bytes but its admission policy declined to keep
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

  defp abort_store(%__MODULE__{} = sink), do: FileSystem.abort_sink(sink.state, sink.cache_opts)

  defp emit_stage_event(cache_status, reason, error, %__MODULE__{} = sink, opts) do
    emit_stage_event(cache_status, reason, error, {sink.key, sink.output_format}, opts)
  end

  defp emit_stage_event(cache_status, reason, error, {%Key{} = key, output_format}, opts) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:cache, :stage],
      %{},
      cache_status
      |> stage_metadata(reason, error, output_format)
      |> Map.put(:cache_key, key.hash)
    )
  end

  defp stage_metadata(:stage_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :stage_error,
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
