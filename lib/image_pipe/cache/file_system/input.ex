defmodule ImagePipe.Cache.FileSystem.Input do
  @moduledoc false
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Input.Output
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.Work
  alias ImagePipe.Source.Record

  def lookup_source(key, opts), do: Output.lookup_source(key, cache_options(opts))

  def acquire_source(key, opts), do: Work.acquire(lock_key(key, opts))
  def release_source(lease, _opts), do: Work.release(lease)

  def publish_source(key, lease, record, path, cost, opts) do
    case Work.publish(lock_key(key, opts), lease, fn ->
           store_original(key, path, record, cost, opts)
           write_source(key, record, opts)
         end) do
      {:ok, result} -> result
      _unavailable -> {:error, :ownership_lost}
    end
  end

  def invalidate_source(key, revision, opts) do
    Output.invalidate_source(key, revision, cache_options(opts), lock_key(key, opts), fn ->
      write_source(key, nil, opts)
    end)
  end

  defp write_source(key, record, opts) do
    previous = previous_body(Output.source_key(key), opts)

    case Output.write_source(key, record, cache_options(opts)) do
      {:ok, snapshot} ->
        current = previous_body(Output.source_key(key), opts)
        if previous && previous != current, do: File.rm(previous)

        verify_source(lookup_source(key, opts), snapshot, key, opts)

      error ->
        error
    end
  end

  defp verify_source({:hit, snapshot}, snapshot, key, opts) do
    if is_nil(snapshot.record), do: Store.delete(key, opts)
    {:ok, snapshot}
  end

  defp verify_source(:miss, %{record: nil} = snapshot, key, opts) do
    Store.delete(key, opts)
    {:ok, snapshot}
  end

  defp verify_source(_result, _snapshot, _key, _opts),
    do: {:error, :source_record_not_stored}

  defp previous_body(key, opts) do
    case Store.get(key, opts) do
      {:hit, file, _metadata} ->
        CacheFile.close(file)
        file.path

      _miss ->
        nil
    end
  end

  defp cache_options(opts), do: [cache: {ImagePipe.Cache.FileSystem, opts}]

  defp lock_key(key, opts),
    do: {__MODULE__, Keyword.fetch!(opts, :root), Keyword.get(opts, :path_prefix, ""), key.hash}

  def open_input(key, record, opts) do
    case Store.get(key, opts) do
      {:hit, file, %{source_record: stored}} ->
        try do
          case Record.valid?(stored) and stored.byte_identity == record.byte_identity do
            true -> pin(file.path)
            false -> :miss
          end
        after
          CacheFile.close(file)
        end

      {:hit, file, _metadata} ->
        CacheFile.close(file)
        {:error, :invalid_metadata}

      other ->
        other
    end
  end

  defp pin(path) do
    pinned = Input.temporary_path(Path.dirname(path))

    case Resources.track(pinned) do
      :unavailable -> :miss
      handle -> pin(path, pinned, handle)
    end
  end

  defp pin(path, pinned, handle) do
    case File.ln(path, pinned) do
      :ok ->
        {:ok, pinned, handle}

      {:error, _} ->
        Resources.release(handle)
        :miss
    end
  end

  def release_input(handle, _opts), do: Resources.release(handle)

  defp store_original(_key, nil, _record, _cost, _opts), do: :ok

  defp store_original(key, path, record, cost, opts) do
    with {:ok, sink} <- Store.open_sink(key, %{source_record: record, cost_us: cost}, opts) do
      try do
        write_original(sink, path, opts)
      after
        Store.abort_sink(sink, opts)
      end
    end
  end

  defp write_original(sink, path, opts) do
    result =
      Enum.reduce_while(File.stream!(path, 65_536), {:ok, sink}, fn chunk, {:ok, state} ->
        case Store.write_chunk(state, chunk, opts) do
          {:ok, next} -> {:cont, {:ok, next}}
          {:error, reason, failed} -> {:halt, {:error, reason, failed}}
        end
      end)

    case result do
      {:ok, state} -> Store.commit_sink(state, opts)
      {:error, reason, _state} -> {:error, reason}
    end
  end
end
