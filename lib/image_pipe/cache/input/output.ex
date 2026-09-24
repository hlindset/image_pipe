defmodule ImagePipe.Cache.Input.Output do
  @moduledoc false
  alias ImagePipe.Cache
  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.File, as: CacheFile
  alias ImagePipe.Cache.Input.Snapshot
  alias ImagePipe.Cache.Key
  alias ImagePipe.Cache.Work

  def lookup_source(key, opts) do
    case Cache.lookup_entry(source_key(key), opts) do
      {:hit, entry} ->
        try do
          {:hit, :erlang.binary_to_term(body(entry.body), [:safe])}
        after
          Entry.close(entry)
        end

      _miss ->
        :miss
    end
  rescue
    ArgumentError -> {:error, :invalid_source_record}
  end

  def acquire_source(key, opts), do: Work.acquire(lock_key(key, opts))
  def release_source(lease, _opts), do: Work.release(lease)

  def publish_source(key, lease, record, nil, _cost, opts) do
    case Work.publish(lock_key(key, opts), lease, fn -> write_source(key, record, opts) end) do
      {:ok, result} -> result
      _unavailable -> {:error, :ownership_lost}
    end
  end

  def invalidate_source(key, revision, opts) do
    invalidate_source(key, revision, opts, lock_key(key, opts), fn ->
      write_source(key, nil, opts)
    end)
  end

  def invalidate_source(key, revision, opts, lock, invalidate) do
    Work.mutate(lock, fn ->
      case lookup_source(key, opts) do
        {:hit, %Snapshot{revision: ^revision}} ->
          invalidate_result(invalidate.())

        _changed ->
          :ok
      end
    end)
  end

  defp invalidate_result({:ok, _snapshot}), do: :ok
  defp invalidate_result(error), do: error

  def write_source(key, nil, opts) do
    case lookup_source(key, opts) do
      :miss -> {:ok, %Snapshot{revision: :crypto.strong_rand_bytes(24), record: nil}}
      _existing -> do_write_source(key, nil, opts)
    end
  end

  def write_source(key, record, opts), do: do_write_source(key, record, opts)

  defp do_write_source(key, record, opts) do
    snapshot = %Snapshot{revision: :crypto.strong_rand_bytes(24), record: record}
    {adapter, pool} = Keyword.fetch!(opts, :cache)
    body = :erlang.term_to_binary(snapshot)

    metadata = %Entry.Metadata{
      content_type: "application/vnd.imagepipe.source",
      headers: [],
      created_at: DateTime.utc_now(),
      output_format: nil,
      representation: {:complete_body, "application/vnd.imagepipe.source"}
    }

    with :ok <- check_size(body, Keyword.get(pool, :max_body_bytes)),
         {:ok, sink} <- adapter.open_sink(source_key(key), metadata, pool) do
      case write_chunk(adapter, sink, body, pool) do
        {:ok, written} ->
          commit_result(adapter.commit_sink(written, pool), snapshot)

        {:error, reason, failed} ->
          adapter.abort_sink(failed, pool)
          {:error, reason}
      end
    end
  end

  defp commit_result(:ok, snapshot), do: {:ok, snapshot}
  defp commit_result({:ok, :rejected}, _snapshot), do: {:error, :admission_rejected}
  defp commit_result({:error, _} = error, _snapshot), do: error

  defp write_chunk(adapter, sink, body, pool) do
    case adapter.write_chunk(sink, body, pool) do
      {:ok, _} = result -> result
      {:error, _, _} = result -> result
      unexpected -> {:error, {:invalid_adapter_result, unexpected}, sink}
    end
  rescue
    exception -> {:error, exception, sink}
  catch
    :exit, reason -> {:error, reason, sink}
  end

  defp check_size(_body, nil), do: :ok
  defp check_size(body, limit) when byte_size(body) <= limit, do: :ok
  defp check_size(_body, _limit), do: {:error, :too_large}

  defp body(body) when is_binary(body), do: body
  defp body(file), do: file |> CacheFile.stream() |> Enum.to_list() |> IO.iodata_to_binary()

  def source_key(%Key{hash: hash}) do
    digest = :crypto.hash(:sha256, "source-record:" <> hash) |> Base.encode16(case: :lower)
    %Key{hash: digest, data: []}
  end

  defp lock_key(key, opts) do
    {adapter, _pool} = Keyword.fetch!(opts, :cache)
    {__MODULE__, adapter, key.hash}
  end
end
