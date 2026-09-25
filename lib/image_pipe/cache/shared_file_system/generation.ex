defmodule ImagePipe.Cache.SharedFileSystem.Generation do
  @moduledoc false

  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.SharedFileSystem.{Body, Metadata, Retention, Storage, Transient}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def descriptor(location, %{body: body, metadata: metadata, metadata_bytes: bytes}) do
    {body_bytes, digest} =
      case body do
        nil -> {0, nil}
        %{bytes: size, sha256: hash} -> {size, hash}
      end

    cost =
      case metadata do
        %{cost_us: cost} -> cost
        _source_record -> 0
      end

    Retention.descriptor(location, bytes + body_bytes, digest, cost)
  end

  def evict(pool, partition, locations, limits, timeout) do
    deadline = deadline(timeout)

    Enum.reduce_while(locations, :ok, fn location, :ok ->
      case run(pool, {Storage, :evict, [partition, location]}, limits, deadline, nil) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  def adopt(pool, plan, location, limits, timeout) do
    deadline = deadline(timeout)
    cleanup = {Transient, :remove, [plan.stage]}

    with {:ok, envelope} <-
           run(pool, {Storage, :metadata, [location, limits.metadata]}, limits, deadline, nil),
         {:ok, _metadata} <- Metadata.decode(location.kind, envelope.metadata),
         {:ok, lease} <-
           CacheIO.reserve(pool, staging_bytes(plan, limits), cleanup, remaining(deadline)) do
      result =
        run(pool, {Storage, :adopt, [plan, location, envelope, limits]}, limits, deadline, lease)

      CacheIO.close(pool, lease)
      result
    end
  end

  def publish(pool, plan, source, metadata, limits, timeout) do
    deadline = deadline(timeout)
    cleanup = {Transient, :remove, [plan.stage]}

    with {:ok, encoded} <- Metadata.encode(metadata, limits.metadata),
         {:ok, lease} <-
           CacheIO.reserve(pool, staging_bytes(plan, limits), cleanup, remaining(deadline)) do
      result =
        run(pool, {Storage, :publish, [plan, source, encoded, limits]}, limits, deadline, lease)

      CacheIO.close(pool, lease)
      result
    end
  end

  def metadata(pool, location, limits, timeout) do
    with {:ok, envelope} <-
           run(
             pool,
             {Storage, :metadata, [location, limits.metadata]},
             limits,
             deadline(timeout),
             nil
           ),
         {:ok, metadata} <- Metadata.decode(location.kind, envelope.metadata) do
      {:ok, %{envelope | metadata: metadata}}
    end
  end

  def acquire(pool, location, reader_root, limits, timeout) do
    deadline = deadline(timeout)
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    directory = Path.join(reader_root, id)
    cleanup = {Transient, :remove, [directory]}

    with {:ok, lease} <- CacheIO.reserve(pool, limits.body, cleanup, remaining(deadline)) do
      result =
        with {:ok, reader} <-
               run(
                 pool,
                 {Storage, :acquire, [location, directory, limits]},
                 limits,
                 deadline,
                 lease
               ),
             {:ok, metadata} <- Metadata.decode(location.kind, reader.metadata) do
          track_reader(lease, %{reader | metadata: metadata}, directory, remaining(deadline))
        end

      case result do
        {:ok, _reader} ->
          result

        error ->
          CacheIO.close(pool, lease)
          error
      end
    end
  end

  def release(pool, reader, timeout) do
    with :ok <- Resources.release(reader.resource, timeout) do
      CacheIO.close(pool, reader.lease)
      :ok
    end
  end

  defp track_reader(lease, reader, directory, timeout) do
    case Resources.track_directory(directory, timeout) do
      :unavailable ->
        {:error, :unavailable}

      resource ->
        {:ok, Map.merge(reader, %{lease: lease, resource: resource})}
    end
  end

  defp run(pool, operation, limits, deadline, lease) do
    case CacheIO.run(
           pool,
           operation,
           Body.working_bytes() + 64 * limits.metadata,
           remaining(deadline),
           lease
         ) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp staging_bytes(%{kind: :sources}, limits), do: limits.metadata
  defp staging_bytes(_plan, limits), do: limits.body + limits.metadata
end
