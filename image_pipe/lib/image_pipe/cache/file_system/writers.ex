defmodule ImagePipe.Cache.FileSystem.Writers do
  # A cache's writers: one process per cache write, so the write's disk work
  # (writing, syncing, closing and committing) runs off the request. They run
  # under this supervisor in the cache's `Root`, after Admission. A shutdown
  # drops the writes still in progress.
  #
  # The pending bytes of a root (written to temp files or held as staged
  # originals, not yet published) are counted in an `:atomics` cell, and a
  # write that would pass the root's limit is dropped, unless it's the only
  # one pending. Admission counts them
  # against `max_size_bytes` too. The limits are guesses (image_plug-sole).
  @moduledoc false

  @max_writers 64
  @max_pending 256 * 1024 * 1024

  @doc "The writer supervisor's child spec for a cache. Sets up its accounting."
  def child_spec(opts) do
    root = Keyword.fetch!(opts, :root)
    limit = min(@max_pending, div(Keyword.fetch!(opts, :max_size_bytes), 20))

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [root, limit]},
      type: :supervisor
    }
  end

  def start_link(root, limit) do
    counters = :atomics.new(2, [])
    :atomics.put(counters, 2, limit)
    :persistent_term.put({__MODULE__, root}, counters)

    DynamicSupervisor.start_link(
      strategy: :one_for_one,
      max_children: @max_writers,
      name: name(root)
    )
  end

  @doc """
  Starts a writer for the cache at `root`. Returns `{:error, :writer_limit}`
  when the cache runs its maximum number of writers, and
  `{:error, :unavailable}` when no instance runs the cache.
  """
  def start_child(root, spec) do
    case DynamicSupervisor.start_child(name(root), spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, :writer_limit}
      {:error, reason} -> {:error, reason}
    end
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc false
  # The running writers of the cache at `root`, for tests that wait on them.
  def writers(root) do
    for {_id, pid, _type, _modules} <- DynamicSupervisor.which_children(name(root)),
        is_pid(pid),
        do: pid
  catch
    :exit, _reason -> []
  end

  @doc """
  The pending-bytes counter of the cache at `root`, or nil when no instance
  runs it. A write takes it when it starts and counts against it until it
  finishes, so a write that outlives a restart of the writers doesn't count
  against the counter the restart sets up.
  """
  def counter(root), do: :persistent_term.get({__MODULE__, root}, nil)

  @doc """
  Counts `bytes` as pending on `counter` for a write that already holds
  `held` of them, or returns `:full` past its limit. A write that is the only
  one pending passes whatever its size, so an entry larger than the limit can
  still be stored.
  """
  def reserve(nil, _bytes, _held), do: :ok

  def reserve(counter, bytes, held) do
    pending = :atomics.add_get(counter, 1, bytes)

    if pending <= :atomics.get(counter, 2) or pending == held + bytes do
      :ok
    else
      :atomics.sub(counter, 1, bytes)
      :full
    end
  end

  @doc "Stops counting `bytes` as pending on `counter`."
  def release(nil, _bytes), do: :ok
  def release(_counter, 0), do: :ok
  def release(counter, bytes), do: :atomics.sub(counter, 1, bytes)

  @doc """
  Records that this process, a writer, holds `bytes` of the pending count, so
  its commit doesn't count them against itself.
  """
  def hold(bytes), do: Process.put({__MODULE__, :held}, bytes)

  @doc "The pending bytes this process holds."
  def held, do: Process.get({__MODULE__, :held}, 0)

  @doc "The bytes pending at `root`."
  def pending(root) do
    case counter(root) do
      nil -> 0
      counter -> :atomics.get(counter, 1)
    end
  end

  # Roots are static host configuration, so the derived atoms are bounded.
  defp name(root) do
    hash = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Module.concat(__MODULE__, hash)
  end
end
