defmodule ImagePipe.Cache.Publication do
  # Runs a source fetch's cache writes off the request, in one of the cache's
  # writers. The writer takes the source's lease (`Work.transfer/3`), so the
  # requests waiting for the source wake when it publishes, or after a
  # deadline. A staged original the writes read is pinned for the writer and
  # counted as pending against the originals cache. The original is dropped
  # when the cache runs its maximum number of writers or its pending bytes
  # would pass the limit, and the other writes still run. Without a running
  # cache, or when the original can't be pinned, the writes run in the
  # request. The deadline and the writer's maximum age are guesses
  # (image_plug-sole).
  @moduledoc false

  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Input
  alias ImagePipe.Cache.Resources
  alias ImagePipe.Cache.Work
  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext

  @lease_deadline 2_000
  @max_age 30_000

  @doc """
  Publishes `write` for the source `hash` under `lease`. `write` is one of:

    * a function,
    * `{:staged, path, put, then}`, where `put` stores the staged original at
      `path`, given the path to read, and `then`, a function or nil, runs
      after it. A dropped original still runs `then`.
    * `{:invalidate, fun}`, which runs even after the lease has expired, since
      dropping an entry is always safe.

  Without an originals cache, a staged original isn't stored, so only `then`
  runs.
  """
  def publish(hash, lease, write, opts) do
    case {writers_root(opts), stored(write, opts)} do
      {_root, nil} -> :ok
      {nil, write} -> run(hash, lease, inline(write), opts)
      {root, write} -> hand_off(root, hash, lease, write, opts)
    end
  end

  defp stored({:staged, _path, _put, then} = write, opts),
    do: if(Keyword.get(opts, :input_cache), do: write, else: then)

  defp stored(write, _opts), do: write

  defp hand_off(root, hash, lease, write, opts) do
    pending = Writers.counter(root)

    with {:ok, writer} <- Writers.start_child(root, job()),
         {:ok, writes, finish} <- prepare(write, writer, pending, hash, opts) do
      send(writer, {:finish, finish})
      Work.transfer(lease, writer, @lease_deadline)
      context = RequestContext.capture()

      send(
        writer,
        {:publish, context,
         fn ->
           run(hash, lease, writes, opts)
           Work.unlock(lease)
         end}
      )

      :ok
    else
      {:error, :unavailable} ->
        run(hash, lease, inline(write), opts)

      {:error, :writer_limit} ->
        run(hash, lease, without_original(write, hash, opts), opts)

      {:error, :unpinned, writer} ->
        send(writer, :cancel)
        run(hash, lease, inline(write), opts)
    end
  end

  # A lease that expired before the writer took the publication lock means
  # another fetch may have written since, so the writes are skipped, except
  # an invalidation.
  defp run(hash, _lease, {:invalidate, fun}, _opts), do: Work.publish(hash, nil, fun)

  defp run(hash, lease, fun, opts) do
    with :unavailable <- Work.publish(hash, lease, fun) do
      dropped(hash, :deadline, opts)
    end
  end

  defp prepare({:staged, path, put, then}, writer, pending, hash, opts) do
    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- Writers.reserve(pending, size) do
      pinned(path, size, writer, pending, put, then)
    else
      :full ->
        dropped(hash, :pending_limit, opts)
        {:ok, fn -> run_then(then) end, fn -> :ok end}

      {:error, _reason} ->
        {:error, :unpinned, writer}
    end
  end

  defp prepare(write, _writer, _pending, _hash, _opts), do: {:ok, write, fn -> :ok end}

  defp pinned(path, size, writer, pending, put, then) do
    case Input.pin(path) do
      {:ok, pinned, ref} ->
        Resources.transfer(ref, writer)

        finish = fn ->
          Resources.release(ref)
          Writers.release(pending, size)
        end

        # The record `then` writes goes to the other cache, so the original's
        # pending bytes are no longer this process's.
        run = fn ->
          Writers.hold(size)
          put.(pinned)
          Writers.hold(0)
          run_then(then)
        end

        {:ok, run, finish}

      :miss ->
        Writers.release(pending, size)
        {:error, :unpinned, writer}
    end
  end

  defp inline({:staged, path, put, then}) do
    fn ->
      put.(path)
      run_then(then)
    end
  end

  defp inline(write), do: write

  # Without a writer, the original isn't stored, but the other writes still
  # run in the request.
  defp without_original({:staged, _path, _put, then}, hash, opts) do
    dropped(hash, :writer_limit, opts)
    fn -> run_then(then) end
  end

  defp without_original(write, _hash, _opts), do: write

  defp run_then(nil), do: :ok
  defp run_then(then), do: then.()

  # The originals cache, when there is one, runs the writer: it takes the
  # large writes.
  defp writers_root(opts) do
    case Keyword.get(opts, :input_cache) || Keyword.get(opts, :cache) do
      nil -> nil
      cache_opts -> Keyword.fetch!(cache_opts, :root)
    end
  end

  defp job, do: Supervisor.child_spec({Task, &await/0}, shutdown: 25_000)

  @doc false
  # The writer owns the reservation from the moment it's made, so a request
  # that dies before handing over the writes, a cancellation, a timeout and a
  # shutdown all release it. A shutdown lets a publication in progress finish.
  def await do
    Process.flag(:trap_exit, true)
    await(fn -> :ok end)
  end

  defp await(finish) do
    receive do
      {:finish, finish} ->
        await(finish)

      {:publish, context, fun} ->
        RequestContext.adopt(context)

        try do
          fun.()
        after
          finish.()
        end

      :cancel ->
        finish.()

      {:EXIT, _from, _reason} ->
        finish.()
    after
      @max_age -> finish.()
    end
  end

  defp dropped(hash, reason, opts) do
    Telemetry.execute(opts, [:cache, :stage], %{}, %{
      result: :ok,
      cache: :stage_dropped,
      reason: reason,
      pool: :input,
      output_format: nil,
      cache_key: hash
    })
  end
end
