defmodule ImagePipe.Cache.FileSystem.Writers do
  # A cache's writers: one process per cache write, so the write's disk work
  # (writing, syncing, closing and committing) runs off the request. They run
  # under this supervisor in the cache's `Root`, after Admission, so a
  # shutdown drains them while Admission still runs.
  #
  # The pending bytes of a root (written to temp files or held as staged
  # originals, not yet published) are counted in an `:atomics` cell, and a
  # write that would pass the root's limit is dropped. Admission counts them
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

  @doc "Counts `bytes` as pending at `root`, or returns `:full` past its limit."
  def reserve(root, bytes) do
    case counters(root) do
      nil ->
        :ok

      counters ->
        if :atomics.add_get(counters, 1, bytes) <= :atomics.get(counters, 2) do
          :ok
        else
          :atomics.sub(counters, 1, bytes)
          :full
        end
    end
  end

  @doc "Stops counting `bytes` as pending at `root`."
  def release(_root, 0), do: :ok

  def release(root, bytes) do
    case counters(root) do
      nil -> :ok
      counters -> :atomics.sub(counters, 1, bytes)
    end
  end

  @doc """
  Records that this process, a writer, holds `bytes` of the pending count, so
  its commit doesn't count them against itself.
  """
  def hold(bytes), do: Process.put({__MODULE__, :held}, bytes)

  @doc "The pending bytes this process holds."
  def held, do: Process.get({__MODULE__, :held}, 0)

  @doc "The bytes pending at `root`."
  def pending(root) do
    case counters(root) do
      nil -> 0
      counters -> :atomics.get(counters, 1)
    end
  end

  defp counters(root), do: :persistent_term.get({__MODULE__, root}, nil)

  # Roots are static host configuration, so the derived atoms are bounded.
  defp name(root) do
    hash = :crypto.hash(:sha256, root) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Module.concat(__MODULE__, hash)
  end
end
