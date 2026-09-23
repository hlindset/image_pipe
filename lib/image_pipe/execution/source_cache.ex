defmodule ImagePipe.Execution.SourceCache do
  @moduledoc false
  alias ImagePipe.Cache
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.Work
  alias ImagePipe.Execution.Overlap
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
      :enabled -> Cache.source_record(key, config) || Input.metadata(key, config)
    end
  end

  def status(nil, _source, _config), do: :requires_validation

  def status(record, source, config),
    do: CacheState.status(Record.state(record, source.cache_semantics), now(config))

  def acquire(source, key, previous, config, need_body?) do
    Work.run(
      {:source, key.hash},
      fn coordination ->
        opts =
          case coordination do
            false -> Keyword.drop(config, [:cache, :input_cache])
            ref -> Keyword.put(config, :source_lease, ref)
          end

        record = lookup(source, key, opts) || previous
        acquire_current(source, key, record, opts, need_body?)
      end,
      Telemetry.telemetry_opts(config)
    )
  end

  def input(source, key, record, config) do
    case Input.open(key, record, config) do
      {:ok, path, lease} ->
        checked_input(record, path, lease, config)

      :miss ->
        Work.run(
          {:source, key.hash},
          fn coordination ->
            open_or_fetch(source, key, record, config, coordination)
          end,
          Telemetry.telemetry_opts(config)
        )
    end
  end

  defp open_or_fetch(source, key, record, config, ref) when is_reference(ref) do
    config = Keyword.put(config, :source_lease, ref)

    case Input.open(key, record, config) do
      {:ok, path, lease} -> checked_input(record, path, lease, config)
      :miss -> fetch(source, key, nil, config)
    end
  end

  defp open_or_fetch(source, key, _record, config, false),
    do: fetch(source, key, nil, Keyword.drop(config, [:cache, :input_cache]))

  defp acquire_current(source, key, record, config, need_body?) do
    case {status(record, source, config), need_body?} do
      {:fresh, false} ->
        {:ok, record, nil, nil, nil}

      {:fresh, true} ->
        case Input.open(key, record, config) do
          {:ok, path, lease} -> checked_input(record, path, lease, config)
          :miss -> fetch(source, key, nil, config)
        end

      _validate ->
        fetch(source, key, record, config)
    end
  end

  defp checked_input(record, path, lease, config) do
    limit = Keyword.fetch!(config, :max_body_bytes)

    case File.stat(path) do
      {:ok, %{size: size}} when size <= limit ->
        {:ok, record, %Response{path: path, origin: record.origin}, lease, nil}

      {:ok, _stat} ->
        Resources.release(lease)
        {:error, {:source, :body_too_large}}

      {:error, _reason} ->
        Resources.release(lease)
        {:error, {:source, :invalid_body}}
    end
  end

  defp fetch(source, key, previous, config) do
    Telemetry.span(Telemetry.telemetry_opts(config), [:cache, :source], %{pool: :input}, fn ->
      started = System.monotonic_time(:microsecond)
      preparation = if is_nil(previous), do: Keyword.get(config, :source_preparation)
      result = fetch_response(source, previous, config, &stage(&1, source, preparation, config))
      cost = System.monotonic_time(:microsecond) - started
      result = publish_coordinated(result, source, key, previous, cost, config)
      {result, %{result: outcome(result)}}
    end)
  end

  defp publish_coordinated(result, source, key, previous, cost, config) do
    publish = fn -> publish(result, source, key, previous, cost, config) end

    case Work.publish(key.hash, Keyword.get(config, :source_lease), publish) do
      {:ok, result} ->
        result

      _unavailable ->
        publish(result, source, key, previous, cost, Keyword.drop(config, [:cache, :input_cache]))
    end
  end

  defp fetch_response(source, %Record{origin: %Source.Origin{} = origin}, config, fun),
    do: Source.with_revalidated(source, origin, config, fun)

  defp fetch_response(source, _previous, config, fun),
    do: Source.with_fetched(source, config, fun)

  defp publish({:not_modified, origin}, source, key, previous, _cost, config) do
    record = Record.refresh(previous, origin)
    remember(source, key, record, config)
    {:ok, record, nil, nil, nil}
  end

  defp publish(
         {:ok, record, response, _lease, _pixels} = result,
         source,
         key,
         _previous,
         cost,
         config
       ) do
    case storable?(record, source) do
      true ->
        if response.path, do: Input.put(key, response.path, record, cost, config)
        Cache.remember_source(key, record, config)

      false ->
        invalidate(key, config)
    end

    result
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
    invalidate(key, config)
    error
  end

  defp publish(error, _source, _key, _previous, _cost, _config), do: error

  defp remember(source, key, record, config) do
    case storable?(record, source) do
      true ->
        Input.refresh(key, record, config)
        Cache.remember_source(key, record, config)

      false ->
        invalidate(key, config)
    end
  end

  def invalidate(key, config) do
    Input.discard(key, config)
    Cache.remember_source(key, nil, config)
  end

  def storable?(record, source),
    do:
      source.internal_cache == :enabled and Record.state(record, source.cache_semantics).storable?

  def release(nil), do: :ok
  def release(lease), do: Resources.release(lease)

  defp stage(response, source, preparation, config) do
    path = Input.temporary_path(System.tmp_dir!())
    lease = Resources.track(path)

    try do
      stream =
        case response.path do
          nil -> response.stream
          path -> File.stream!(path, 65_536)
        end

      {:ok, body, digest, pixels} =
        case lease do
          :unavailable -> spool_buffer(stream, config[:max_body_bytes])
          _ref -> spool(stream, path, response, source, preparation, config)
        end

      record = Record.new(source, digest, response.origin, now(config))
      prepared = staged_response(body, path, response.origin)
      {:ok, record, prepared, lease, pixels}
    rescue
      exception in Source.StreamError ->
        release(lease)
        {:error, {:source, exception.reason}}

      _exception ->
        release(lease)
        {:error, {:source, :stream_exception}}
    catch
      _kind, _reason ->
        release(lease)
        {:error, {:source, :stream_exception}}
    end
  end

  defp staged_response(:file, path, origin), do: %Response{path: path, origin: origin}

  defp staged_response({:buffer, bytes}, _path, origin),
    do: %Response{stream: [bytes], origin: origin}

  defp spool(stream, path, response, source, preparation, config) do
    case File.open(path, [:read, :write, :binary, :exclusive]) do
      {:ok, io} ->
        try do
          Overlap.with_session(response, source, preparation, config, path, fn overlap ->
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
      Enum.reduce(stream, initial, fn bytes, {body, size, hash, overlap} ->
        next_size = size + byte_size(bytes)
        check_size!(next_size, limit)
        body = append(body, io, bytes, size)

        {:ok, overlap} = observe(body, overlap, io, next_size)
        {body, next_size, :crypto.hash_update(hash, bytes), overlap}
      end)

    {:ok, pixels} = Overlap.finish(overlap, size)
    {:ok, finish_body(body), :crypto.hash_final(hash), pixels}
  end

  defp observe(:file, overlap, io, size), do: Overlap.observe(overlap, io, size)
  defp observe({:buffer, _}, overlap, _io, _size), do: {:ok, Overlap.cancel(overlap)}

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
    {bytes, _size, hash} =
      Enum.reduce(stream, {[], 0, :crypto.hash_init(:sha256)}, fn bytes, {acc, size, hash} ->
        check_size!(size + byte_size(bytes), limit)
        {[bytes | acc], size + byte_size(bytes), :crypto.hash_update(hash, bytes)}
      end)

    {:ok, {:buffer, bytes |> Enum.reverse() |> IO.iodata_to_binary()}, :crypto.hash_final(hash),
     nil}
  end

  defp check_size!(size, limit) when size > limit,
    do: raise(Source.StreamError, reason: :body_too_large)

  defp check_size!(_size, _limit), do: :ok
  defp outcome({:ok, _, _, _, _}), do: :ok
  defp outcome({:error, _} = error), do: Telemetry.request_result(error)
end
