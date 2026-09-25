defmodule ImagePipe.Cache.SharedFileSystem.Sink do
  @moduledoc false

  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.{Locations, Retainer, Runtime, Transient}

  def open(key, metadata, opts) do
    with {:ok, context} <- Runtime.context(opts[:runtime]) do
      deadline = System.monotonic_time(:millisecond) + opts[:timeout]

      directory =
        Path.join(context.readers, Base.encode16(:crypto.strong_rand_bytes(16), case: :lower))

      limit = min(opts[:max_body_bytes] || context.limits.body, context.limits.body)

      with {:ok, lease} <-
             CacheIO.reserve(
               context.pool,
               limit,
               {Transient, :remove, [directory]},
               remaining(deadline)
             ) do
        state = %{
          context: context,
          key: key.hash,
          metadata: metadata,
          lease: lease,
          path: Path.join(directory, "body"),
          size: 0,
          limit: limit,
          budget: remaining(deadline)
        }

        stage(state, directory)
      end
    end
  end

  defp stage(state, directory) do
    deadline = System.monotonic_time(:millisecond) + state.budget

    case CacheIO.run(
           state.context.pool,
           {__MODULE__, :create, [directory]},
           0,
           remaining(deadline),
           state.lease
         ) do
      {:ok, :ok} ->
        {:ok, %{state | budget: remaining(deadline)}}

      error ->
        CacheIO.close(state.context.pool, state.lease)
        unwrap(error)
    end
  end

  def write(state, chunk, _opts) do
    deadline = System.monotonic_time(:millisecond) + state.budget
    next = %{state | size: state.size + byte_size(chunk)}

    case next.size <= state.limit do
      false ->
        {:error, :body_too_large, state}

      true ->
        case CacheIO.run(
               state.context.pool,
               {File, :write, [state.path, chunk, [:append]]},
               byte_size(chunk),
               remaining(deadline),
               state.lease
             ) do
          {:ok, :ok} -> {:ok, %{next | budget: remaining(deadline)}}
          error -> {:error, elem(unwrap(error), 1), %{next | budget: remaining(deadline)}}
        end
    end
  end

  def commit(state, _opts) do
    deadline = System.monotonic_time(:millisecond) + state.budget
    context = state.context

    case Retainer.publish(
           context.retainer,
           :outputs,
           state.key,
           state.path,
           state.metadata,
           state.size,
           remaining(deadline)
         ) do
      {:ok, location} ->
        Locations.remember(context.locations, location, remaining(deadline))
        :ok

      error ->
        error
    end
  after
    CacheIO.close(state.context.pool, state.lease)
  end

  def abort(state, _opts), do: CacheIO.close(state.context.pool, state.lease)

  # Run only in the isolated helper; creation belongs to the reserved lease.
  def create(directory) do
    with :ok <- File.mkdir(directory),
         do: File.write(Path.join(directory, "body"), "", [:exclusive])
  end

  defp unwrap({:ok, result}), do: result
  defp unwrap(error), do: error
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
