defmodule ImagePipe.Cache.SharedFileSystem.Generation do
  @moduledoc false

  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.SharedFileSystem.{Body, Storage, Transient}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO

  def publish(pool, plan, source, metadata, limits, timeout) do
    deadline = deadline(timeout)
    cleanup = {Transient, :remove, [plan.stage]}

    with :ok <- metadata_size(metadata, limits.metadata),
         {:ok, lease} <-
           CacheIO.reserve(pool, limits.body + limits.metadata, cleanup, remaining(deadline)) do
      result =
        run(pool, {Storage, :publish, [plan, source, metadata, limits]}, limits, deadline, lease)

      CacheIO.close(pool, lease)
      result
    end
  end

  def acquire(pool, location, reader_root, limits, timeout) do
    deadline = deadline(timeout)
    id = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    directory = Path.join(reader_root, id)
    cleanup = {Transient, :remove, [directory]}

    with {:ok, lease} <- CacheIO.reserve(pool, limits.body, cleanup, remaining(deadline)) do
      case run(pool, {Storage, :acquire, [location, directory, limits]}, limits, deadline, lease) do
        {:ok, reader} ->
          track_reader(pool, lease, reader, directory, remaining(deadline))

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

  defp track_reader(pool, lease, reader, directory, timeout) do
    case Resources.track_directory(directory, timeout) do
      :unavailable ->
        CacheIO.close(pool, lease)
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

  defp metadata_size(metadata, limit) do
    case :erlang.external_size(metadata) <= limit do
      true -> :ok
      false -> {:error, :metadata_too_large}
    end
  end
end
