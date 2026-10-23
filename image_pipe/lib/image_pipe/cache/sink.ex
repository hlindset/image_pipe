defmodule ImagePipe.Cache.Sink do
  # The request's side of a cache write. Opening it starts a writer
  # (`ImagePipe.Cache.Writer`) that does the disk work. Chunks are sent to the
  # writer without waiting, and a commit hands it the output lease and
  # returns. The write is dropped when the cache runs its maximum number of
  # writers, when its pending bytes would pass the cache's limit, or when the
  # client gets more than `@max_lead` bytes ahead of the writer. Those limits,
  # and the lease deadline, are guesses (image_plug-sole).
  @moduledoc false

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Lookups
  alias ImagePipe.Cache.OutputWork
  alias ImagePipe.Cache.Writer
  alias ImagePipe.Format
  alias ImagePipe.Output.Resolved
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  @max_lead 8 * 1024 * 1024
  @lease_deadline 2_000

  @enforce_keys [
    :key,
    :pending,
    :writer,
    :counters,
    :size,
    :max_body_bytes,
    :output_format,
    :telemetry_opts
  ]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          key: Key.t(),
          pending: :atomics.atomics_ref() | nil,
          writer: pid(),
          counters: :atomics.atomics_ref(),
          size: non_neg_integer(),
          max_body_bytes: non_neg_integer() | nil,
          output_format: atom() | nil,
          telemetry_opts: keyword()
        }

  @spec open(
          Key.t(),
          Resolved.t() | {:complete_body, String.t()},
          keyword(),
          keyword(),
          keyword()
        ) :: t() | nil
  def open(%Key{} = key, %Resolved{} = resolved_output, cache_opts, facts, opts) do
    cost_us = Keyword.get(facts, :cost_us, 0)
    debug = Keyword.get(facts, :debug)

    case response_metadata(resolved_output, cost_us, debug) do
      {:ok, metadata} ->
        start(key, metadata, cache_opts, opts)

      {:error, reason} ->
        handle_open_error(reason, key, resolved_output.format, opts)
        nil
    end
  end

  # Complete-body sink: a non-image body (e.g. a BlurHash
  # string) delivered whole, with no encoder output and no `%Resolved{}`.
  def open(%Key{} = key, {:complete_body, content_type}, cache_opts, facts, opts)
      when is_binary(content_type) do
    cost_us = Keyword.get(facts, :cost_us, 0)
    debug = Keyword.get(facts, :debug)

    metadata = complete_body_metadata(content_type, cost_us, debug)
    start(key, metadata, cache_opts, opts)
  end

  @spec write_chunk(t() | nil, binary(), keyword()) :: t() | nil
  def write_chunk(nil, _chunk, _opts), do: nil

  def write_chunk(%__MODULE__{} = sink, chunk, _opts) when is_binary(chunk) do
    size = sink.size + byte_size(chunk)

    cond do
      sink.max_body_bytes != nil and size > sink.max_body_bytes ->
        drop(sink, :stage_skipped, :too_large)

      size - byte_size(chunk) - Writer.confirmed(sink.counters) > @max_lead ->
        drop(sink, :stage_dropped, :lagging)

      true ->
        send_chunk(%{sink | size: size}, chunk)
    end
  end

  # Without a sink, the lease completes here, as no entry is coming.
  @spec commit(t() | nil, keyword(), OutputWork.lease() | nil) :: :ok
  def commit(sink, opts, lease \\ nil)

  def commit(nil, _opts, lease) do
    OutputWork.complete(lease, :ready)
    :ok
  end

  def commit(%__MODULE__{} = sink, _opts, lease) do
    if Writer.finished?(sink.counters) do
      OutputWork.complete(lease, :ready)
    else
      OutputWork.transfer(lease, sink.writer, @lease_deadline)
      send(sink.writer, {:commit, lease})
    end

    :ok
  end

  @spec abort(t() | nil, atom(), keyword()) :: :ok
  def abort(nil, _reason, _opts), do: :ok

  # A writer that already finished reported why.
  def abort(%__MODULE__{} = sink, reason, _opts) do
    send(sink.writer, {:abort, reason})

    if not Writer.finished?(sink.counters),
      do: emit_stage_event(:stage_abandoned, reason, nil, sink)

    :ok
  end

  @doc false
  # Stores a complete body from the calling process, without a writer, for a
  # caller that already runs off the request. Returns the commit's result.
  def store(%Key{} = key, content_type, body, cache_opts, facts, opts) do
    metadata = complete_body_metadata(content_type, Keyword.get(facts, :cost_us, 0), nil)

    start_metadata = %{pool: :output, cache_key: key.hash}

    Telemetry.span(opts, [:cache, :write], start_metadata, fn ->
      result = store_body(key, metadata, body, cache_opts)
      if match?({:error, _reason}, result), do: Lookups.count(cache_opts, :write_error)
      {result, commit_metadata(result, key, nil, byte_size(body), nil)}
    end)
  end

  defp store_body(key, metadata, body, cache_opts) do
    with {:ok, store} <- FileSystem.open_sink(key, metadata, cache_opts) do
      case FileSystem.write_chunk(store, body, cache_opts) do
        {:ok, store} ->
          FileSystem.commit_sink(store, cache_opts)

        {:error, reason, store} ->
          FileSystem.abort_sink(store, cache_opts)
          {:error, reason}
      end
    end
  end

  @doc false
  # A writer that couldn't open its temp body reports it.
  def open_failed(writer_state, reason) do
    emit_stage_event(:stage_error, :open, reason, writer_state)
  end

  @doc false
  # A writer whose disk write failed reports it, as the sink did before.
  def write_failed(writer_state, reason) do
    emit_stage_event(:stage_error, :write, reason, writer_state)
  end

  @doc false
  def dropped(writer_state, reason),
    do: emit_stage_event(:stage_dropped, reason, nil, writer_state)

  @doc false
  # The `[:cache, :write]` stop metadata for a commit's result. A source
  # record has no render cost.
  def commit_metadata(result, %Key{} = key, output_format, size, cost_us) do
    result
    |> commit_stop_metadata(output_format)
    |> Map.merge(%{cache_key: key.hash, bytes: size})
    |> put_cost(cost_us)
  end

  defp put_cost(metadata, nil), do: metadata
  defp put_cost(metadata, cost_us), do: Map.put(metadata, :estimated_cost_us, cost_us)

  defp start(key, metadata, cache_opts, opts) do
    root = Keyword.fetch!(cache_opts, :root)
    pending = Writers.counter(root)
    counters = Writer.counters()
    telemetry_opts = Telemetry.telemetry_opts(opts)

    args = %{
      key: key,
      metadata: metadata,
      cache_opts: cache_opts,
      pending: pending,
      counters: counters,
      output_format: metadata.output_format,
      telemetry_opts: telemetry_opts,
      request_context: RequestContext.capture()
    }

    case Writers.start_child(root, {Writer, args}) do
      {:ok, writer} ->
        %__MODULE__{
          key: key,
          pending: pending,
          writer: writer,
          counters: counters,
          size: 0,
          max_body_bytes: Keyword.get(cache_opts, :max_body_bytes),
          output_format: metadata.output_format,
          telemetry_opts: telemetry_opts
        }

      {:error, :writer_limit} ->
        emit_stage_event(:stage_dropped, :writer_limit, nil, {key, metadata.output_format}, opts)
        nil

      # No instance runs this cache.
      {:error, :unavailable} ->
        nil
    end
  end

  defp send_chunk(sink, chunk) do
    case Writer.reserve(sink.counters, sink.pending, byte_size(chunk)) do
      :ok ->
        send(sink.writer, {:chunk, chunk})
        sink

      # The writer already reported why it stopped.
      :finished ->
        nil

      :full ->
        drop(sink, :stage_dropped, :pending_limit)
    end
  end

  defp drop(sink, status, reason) do
    send(sink.writer, {:abort, reason})
    emit_stage_event(status, reason, nil, sink)
    nil
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

  defp handle_open_error(reason, key, output_format, opts) do
    emit_stage_event(:stage_error, :open, reason, {key, output_format}, opts)
  end

  defp commit_stop_metadata(:ok, output_format),
    do: %{result: :ok, cache: :write, output_format: output_format}

  # The cache accepted the bytes but its admission policy declined to keep
  # the entry. This is a successful, non-error outcome: nothing was stored,
  # so the request path is unaffected (fail-open). Report it on the write
  # span the same way `:write_error` is reported — commit-level outcomes
  # live on `[:cache, :write]`, not on a separate stage event.
  defp commit_stop_metadata({:ok, :rejected}, output_format),
    do: %{result: :ok, cache: :admission_rejected, output_format: output_format}

  defp commit_stop_metadata({:error, reason}, output_format) do
    %{
      result: :cache_error,
      cache: :write_error,
      error: Telemetry.error_tag(reason),
      output_format: output_format
    }
  end

  # The sink and the writer's state both carry the key, output format and
  # telemetry options.
  defp emit_stage_event(cache_status, reason, error, %{telemetry_opts: telemetry_opts} = write),
    do: emit(cache_status, reason, error, write.key, write.output_format, telemetry_opts)

  defp emit_stage_event(cache_status, reason, error, {%Key{} = key, output_format}, opts),
    do: emit(cache_status, reason, error, key, output_format, opts)

  defp emit(cache_status, reason, error, key, output_format, telemetry_opts) do
    Telemetry.execute(
      telemetry_opts,
      [:cache, :stage],
      %{},
      cache_status
      |> stage_metadata(reason, error, output_format)
      |> Map.merge(%{pool: :output, cache_key: key.hash})
    )
  end

  defp stage_metadata(:stage_error, _reason, error, output_format),
    do: %{
      result: :cache_error,
      cache: :stage_error,
      error: Telemetry.error_tag(error),
      output_format: output_format
    }

  defp stage_metadata(cache_status, reason, _error, output_format),
    do: %{
      result: :ok,
      cache: cache_status,
      reason: reason,
      output_format: output_format
    }
end
