defmodule ImagePipe.Cache.SharedFileSystem.Generation do
  @moduledoc false

  alias ImagePipe.Cache.Resources

  alias ImagePipe.Cache.SharedFileSystem.{
    Body,
    Metadata,
    Partition,
    Retention,
    Storage,
    Transient
  }

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

  def planned_descriptor(plan, metadata, size, limits) do
    body =
      case plan.kind do
        :sources -> nil
        _body -> %{bytes: size, sha256: <<0::256>>}
      end

    with {:ok, encoded} <- Metadata.encode(metadata, limits.metadata) do
      bytes = plan |> Storage.envelope(body, encoded) |> :erlang.external_size()

      location =
        Partition.location(
          plan.parent,
          plan.kind,
          plan.key,
          plan.generation
        )

      cond do
        size > limits.body ->
          {:error, :body_too_large}

        bytes > limits.metadata ->
          {:error, :metadata_too_large}

        true ->
          {:ok,
           descriptor(
             location,
             %{body: body, metadata: metadata, metadata_bytes: bytes}
           )}
      end
    end
  end

  def publish_retained(pool, plan, source, metadata, limits, timeout, observer) do
    deadline = deadline(timeout)

    with {:ok, location} <-
           publish(pool, plan, source, metadata, limits, remaining(deadline), observer) do
      case metadata(pool, location, limits, remaining(deadline)) do
        {:ok, envelope} -> {:ok, descriptor(location, envelope)}
        {:error, reason} -> {:error, {:published_metadata, reason}}
      end
    end
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

  def adopt(pool, plan, location, limits, timeout, observer \\ nil) do
    deadline = deadline(timeout)
    cleanup = {Transient, :remove_stage, [plan.stage, plan.parent]}

    with {:ok, envelope} <-
           run(pool, {Storage, :metadata, [location, limits.metadata]}, limits, deadline, nil),
         {:ok, _metadata} <- Metadata.decode(location.kind, envelope.metadata),
         {:ok, lease} <-
           CacheIO.reserve(pool, staging_bytes(plan, limits), cleanup, remaining(deadline)) do
      result =
        run(
          pool,
          {Storage, :adopt, [plan, location, envelope, limits]},
          limits,
          deadline,
          lease,
          observer
        )

      CacheIO.close(pool, lease)
      result
    else
      error ->
        not_started(observer, error)
        error
    end
  end

  def publish(pool, plan, source, metadata, limits, timeout, observer \\ nil) do
    deadline = deadline(timeout)
    cleanup = {Transient, :remove_stage, [plan.stage, plan.parent]}

    with {:ok, encoded} <- Metadata.encode(metadata, limits.metadata),
         {:ok, lease} <-
           CacheIO.reserve(pool, staging_bytes(plan, limits), cleanup, remaining(deadline)) do
      result =
        run(
          pool,
          {Storage, :publish, [plan, source, encoded, limits]},
          limits,
          deadline,
          lease,
          observer
        )

      CacheIO.close(pool, lease)
      result
    else
      error ->
        not_started(observer, error)
        error
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

  def verify(pool, location, limits, timeout) do
    with {:ok, envelope} <-
           run(pool, {Storage, :verify, [location, limits]}, limits, deadline(timeout), nil),
         {:ok, metadata} <- Metadata.decode(location.kind, envelope.metadata),
         do: {:ok, descriptor(location, %{envelope | metadata: metadata})}
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
          reader = %{reader | metadata: metadata}
          reader = Map.put(reader, :descriptor, descriptor(location, reader))
          track_reader(lease, reader, directory, remaining(deadline))
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

  defp run(pool, operation, limits, deadline, lease, observer \\ nil) do
    case CacheIO.run(
           pool,
           operation,
           Body.working_bytes() + 64 * limits.metadata,
           remaining(deadline),
           lease,
           observer
         ) do
      {:ok, result} -> result
      error -> error
    end
  end

  defp not_started(nil, _error), do: :ok

  defp not_started({pid, receipt}, error),
    do: send(pid, {:shared_io_complete, receipt, {:not_started, error}})

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp staging_bytes(%{kind: :sources}, limits), do: limits.metadata
  defp staging_bytes(_plan, limits), do: limits.body + limits.metadata
end
