defmodule ImagePipe.Execution.SourceCache do
  @moduledoc false
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Input.Snapshot
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Execution.{Acquisition, Overlap}
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheState
  alias ImagePipe.Source.Record
  alias ImagePipe.Source.Response
  alias ImagePipe.Telemetry

  def enabled?(source, config) do
    source.source_kind in [:url, :object] and
      (Keyword.has_key?(config, :cache) or Keyword.has_key?(config, :input_cache))
  end

  def now(config), do: Keyword.get(config, :clock, fn -> System.system_time(:second) end).()

  def trusted_record(source, config) do
    semantics = source.cache_semantics

    if semantics.stable? and Keyword.get(semantics.policy, :storage) == :allow do
      Record.new(source, nil, nil, now(config))
    end
  end

  def lookup(source, key, config) do
    case source.internal_cache do
      :disabled -> nil
      :enabled -> Input.lookup(key, config)
    end
  end

  def status(nil, _source, _config), do: :requires_validation

  def status(%Snapshot{record: record}, source, config), do: status(record, source, config)

  def status(record, source, config),
    do: CacheState.status(Record.state(record, source.cache_semantics), now(config))

  def acquisition(%Snapshot{record: record, revision: revision}),
    do: %Acquisition{record: record, source_revision: revision}

  def acquisition(record), do: %Acquisition{record: record}

  def acquire(source, key, preparation, config) do
    case Input.acquire(key, config) do
      {:ok, lease} ->
        try do
          opts = Keyword.put(config, :source_lease, lease)
          snapshot = lookup(source, key, opts)

          case status(snapshot, source, opts) do
            :fresh -> {:ok, acquisition(snapshot)}
            _validate -> fetch(source, key, record(snapshot), preparation, opts)
          end
        after
          Input.release_source(lease)
        end

      :bypass ->
        fetch(source, key, nil, preparation, Keyword.drop(config, [:cache, :input_cache]))
    end
  end

  def input(source, key, acquisition, preparation, config) do
    case Input.open(key, acquisition.record, config) do
      {:ok, path, lease} ->
        checked_input(acquisition, path, lease, config)

      :miss ->
        open_or_fetch(source, key, preparation, config)
    end
  end

  defp open_or_fetch(source, key, preparation, config) do
    case Input.acquire(key, config) do
      {:ok, lease} ->
        try do
          opts = Keyword.put(config, :source_lease, lease)
          snapshot = lookup(source, key, opts)

          case {record(snapshot), status(snapshot, source, opts)} do
            {%Record{} = current, :fresh} ->
              case Input.open(key, current, opts) do
                {:ok, path, handle} -> checked_input(acquisition(snapshot), path, handle, opts)
                :miss -> fetch(source, key, nil, preparation, opts)
              end

            _validate ->
              fetch(source, key, nil, preparation, opts)
          end
        after
          Input.release_source(lease)
        end

      :bypass ->
        fetch(source, key, nil, preparation, Keyword.drop(config, [:cache, :input_cache]))
    end
  end

  defp record(nil), do: nil
  defp record(%Snapshot{record: record}), do: record

  defp checked_input(acquisition, path, lease, config) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{size: size}} when size <= limit ->
        {:ok,
         %{
           acquisition
           | response: %Response{path: path, origin: acquisition.record.origin},
             lease: lease,
             source_bytes: size
         }}

      {:ok, _stat} ->
        Input.release(lease)
        {:error, {:source, :body_too_large}}

      {:error, _reason} ->
        Input.release(lease)
        {:error, {:source, :invalid_body}}
    end
  end

  defp fetch(source, key, previous, preparation, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:cache, :source], %{pool: :input}, fn ->
      started = System.monotonic_time(:microsecond)
      preparation = if is_nil(previous), do: preparation
      result = fetch_response(source, previous, config, &stage(&1, source, preparation, config))
      cost = System.monotonic_time(:microsecond) - started
      result = publish(result, source, key, previous, cost, config)
      {result, %{result: outcome(result)}}
    end)
  end

  defp fetch_response(source, %Record{origin: %Source.Origin{} = origin}, config, fun),
    do: Source.with_revalidated(source, origin, config, fun)

  defp fetch_response(source, _previous, config, fun),
    do: Source.with_fetched(source, config, fun)

  defp publish({:not_modified, origin}, source, key, previous, _cost, config) do
    record = Record.refresh(previous, origin)
    {:ok, remember(%Acquisition{record: record}, source, key, 0, config)}
  end

  defp publish(
         {:ok, %Acquisition{} = acquisition},
         source,
         key,
         _previous,
         cost,
         config
       ) do
    {:ok, remember(acquisition, source, key, cost, config)}
  end

  defp publish(
         {:error, {:source, {:bad_status, status}}} = error,
         _source,
         key,
         _previous,
         _cost,
         config
       )
       when status in [401, 403, 404, 410] do
    publish_record(key, nil, nil, 0, config)
    error
  end

  defp publish(error, _source, _key, _previous, _cost, _config), do: error

  defp remember(acquisition, source, key, cost, config) do
    case storable?(acquisition.record, source) do
      true ->
        path = if acquisition.response, do: acquisition.response.path

        case publish_record(key, acquisition.record, path, cost, config) do
          {:ok, %Snapshot{revision: revision}} -> %{acquisition | source_revision: revision}
          _failed -> acquisition
        end

      false ->
        publish_record(key, nil, nil, 0, config)
        acquisition
    end
  end

  defp publish_record(key, record, path, cost, config) do
    case Keyword.get(config, :source_lease) do
      nil -> {:error, :uncoordinated}
      lease -> Input.publish(key, lease, record, path, cost, config)
    end
  end

  def invalidate(key, revision, config), do: Input.invalidate(key, revision, config)

  def storable?(record, source),
    do:
      source.internal_cache == :enabled and Record.state(record, source.cache_semantics).storable?

  def release(nil), do: :ok
  def release(lease), do: Input.release(lease)

  defp stage(response, source, preparation, config) do
    path = Input.temporary_path(System.tmp_dir!())
    lease = Resources.track(path)

    try do
      stream =
        case response.path do
          nil -> response.stream
          path -> File.stream!(path, 65_536)
        end

      {body, digest, size, processing} =
        case lease do
          :unavailable -> spool_buffer(stream, config[:max_body_bytes])
          _ref -> spool(stream, path, response, preparation, config)
        end

      record = Record.new(source, digest, response.origin, now(config))
      prepared = staged_response(body, path, response.origin)

      {:ok,
       %Acquisition{
         record: record,
         response: prepared,
         lease: lease,
         source_bytes: size,
         processing: processing
       }}
    rescue
      exception in Source.StreamError ->
        release(lease)
        {:error, {:source, exception.reason}}
    catch
      kind, reason ->
        release(lease)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp staged_response(:file, path, origin), do: %Response{path: path, origin: origin}

  defp staged_response({:buffer, bytes}, _path, origin),
    do: %Response{stream: [bytes], origin: origin}

  defp spool(stream, path, response, preparation, config) do
    case File.open(path, [:read, :write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          Overlap.with_session(response, preparation, config, path, fn overlap ->
            spool_file(stream, io, config[:max_body_bytes], overlap)
          end)
        after
          File.close(io)
        end

      {:error, _reason} ->
        spool_buffer(stream, config[:max_body_bytes])
    end
  end

  defp spool_file(stream, io, limit, overlap) do
    initial = {:file, 0, :crypto.hash_init(:sha256), overlap}

    {body, size, hash, overlap} =
      Source.reduce_body(stream, initial, fn bytes, {body, size, hash, overlap} ->
        next_size = size + byte_size(bytes)
        check_size!(next_size, limit)
        body = append(body, io, bytes, size)

        overlap = observe(body, overlap, io, next_size)
        {body, next_size, :crypto.hash_update(hash, bytes), overlap}
      end)

    {finish_body(body), :crypto.hash_final(hash), size, Overlap.finish(overlap)}
  end

  defp observe(:file, overlap, io, size), do: Overlap.observe(overlap, io, size)
  defp observe({:buffer, _}, overlap, _io, _size), do: Overlap.cancel(overlap)

  defp append(:file, io, bytes, size) do
    case :file.write(io, bytes) do
      :ok ->
        :file

      {:error, _reason} ->
        {:ok, prefix} = :file.pread(io, 0, size)
        {:buffer, [bytes, prefix]}
    end
  end

  defp append({:buffer, reversed}, _io, bytes, _size), do: {:buffer, [bytes | reversed]}
  defp finish_body(:file), do: :file

  defp finish_body({:buffer, reversed}),
    do: {:buffer, reversed |> Enum.reverse() |> IO.iodata_to_binary()}

  defp spool_buffer(stream, limit) do
    {bytes, size, hash} =
      Source.reduce_body(stream, {[], 0, :crypto.hash_init(:sha256)}, fn bytes,
                                                                         {acc, size, hash} ->
        check_size!(size + byte_size(bytes), limit)
        {[bytes | acc], size + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end)

    {{:buffer, bytes |> Enum.reverse() |> IO.iodata_to_binary()}, :crypto.hash_final(hash), size,
     nil}
  end

  defp check_size!(size, limit) when size > limit,
    do: raise(Source.StreamError, reason: :body_too_large)

  defp check_size!(_size, _limit), do: :ok
  defp outcome({:ok, %Acquisition{}}), do: :ok
  defp outcome({:error, _} = error), do: Telemetry.request_result(error)
end
