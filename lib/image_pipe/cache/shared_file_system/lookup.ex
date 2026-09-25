defmodule ImagePipe.Cache.SharedFileSystem.Lookup do
  @moduledoc false

  alias ImagePipe.Cache.Input.Snapshot
  alias ImagePipe.Cache.SharedFileSystem.{Generation, Locations, Partition, Retainer, Sources}

  # The caller owns acquired readers and source leases. Only enumeration is
  # coalesced: each request needs its own stable reader lifetime.
  def output(context, key, timeout), do: lookup(context, :outputs, key, :body, timeout)

  def original(context, input_key, record, timeout) do
    key = Partition.original_key(input_key, record.byte_identity)
    lookup(context, :originals, key, {:original, record.byte_identity}, timeout)
  end

  def source(context, key, lease, timeout),
    do: lookup(context, :sources, key, {:source, lease}, timeout)

  defp lookup(context, kind, key, operation, timeout) do
    request = %{
      context: context,
      kind: kind,
      key: key,
      operation: operation,
      deadline: System.monotonic_time(:millisecond) + timeout,
      seen: MapSet.new(),
      attempts: 0
    }

    Retainer.request(context.retainer, kind, key, remaining(request))

    case Locations.hints(context.locations, kind, key, remaining(request)) do
      {:ok, hints} -> try_hints(request, hints)
      error -> error
    end
  end

  defp try_hints(request, hints) do
    case candidates(request, hints) do
      {:miss, request} -> discover(request, :cached)
      result -> result
    end
  end

  defp discover(request, mode) do
    context = request.context

    case Locations.discover(
           context.locations,
           request.kind,
           request.key,
           mode,
           remaining(request)
         ) do
      {:ok, [], :complete} ->
        :miss

      {:ok, locations, status} ->
        case candidates(request, locations) do
          {:miss, request} -> after_miss(request, mode, status)
          result -> result
        end

      error ->
        error
    end
  end

  defp after_miss(_request, _mode, :limited), do: {:error, :search_limit}
  defp after_miss(request, :cached, :complete), do: discover(request, :refresh)
  defp after_miss(_request, :refresh, :complete), do: :miss

  defp candidates(request, []), do: {:miss, request}

  defp candidates(request, [location | rest]) do
    cond do
      remaining(request) == 0 ->
        {:error, :timeout}

      MapSet.member?(request.seen, location) ->
        candidates(request, rest)

      request.attempts >= request.context.max_attempts ->
        {:error, :search_limit}

      true ->
        request = %{
          request
          | seen: MapSet.put(request.seen, location),
            attempts: request.attempts + 1
        }

        attempt(request, location, rest)
    end
  end

  defp attempt(request, location, rest) do
    case open(request, location) do
      {:hit, value} ->
        Locations.remember(request.context.locations, location, remaining(request))
        {:hit, value}

      {:error, reason} when reason in [:timeout, :saturated, :unavailable, :ownership_lost] ->
        {:error, reason}

      _unusable ->
        Locations.forget(request.context.locations, location, remaining(request))
        candidates(request, rest)
    end
  end

  defp open(%{operation: {:source, lease}} = request, location) do
    context = request.context

    with {:ok, %{metadata: record} = envelope} <-
           Generation.metadata(context.pool, location, context.limits, remaining(request)) do
      snapshot = %Snapshot{revision: {location.path, location.generation}, record: record}

      case Sources.discover(context.sources, request.key, lease, snapshot, remaining(request)) do
        {:hit, _selected} = hit ->
          Retainer.consider(
            context.retainer,
            Generation.descriptor(location, envelope),
            remaining(request)
          )

          hit

        result ->
          result
      end
    end
  end

  defp open(request, location) do
    context = request.context

    with {:ok, reader} <-
           Generation.acquire(
             context.pool,
             location,
             context.readers,
             context.limits,
             remaining(request)
           ) do
      case accept_reader(request, reader) do
        {:hit, _reader} = hit ->
          Retainer.consider(context.retainer, reader.descriptor, remaining(request))
          hit

        error ->
          error
      end
    end
  end

  defp accept_reader(%{operation: :body}, reader), do: {:hit, reader}

  defp accept_reader(%{operation: {:original, identity}} = request, reader) do
    case reader.metadata.source_record.byte_identity == identity do
      true ->
        {:hit, reader}

      false ->
        Generation.release(request.context.pool, reader, remaining(request))
        {:error, :identity_mismatch}
    end
  end

  defp remaining(request),
    do: max(request.deadline - System.monotonic_time(:millisecond), 0)
end
