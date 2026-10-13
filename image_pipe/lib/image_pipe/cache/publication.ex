defmodule ImagePipe.Cache.Publication do
  # Runs a source fetch's cache writes off the request, in one of the cache's
  # writers. The writer takes the source's lease (`Work.transfer/3`), so the
  # requests waiting for the source wake when it publishes, or after a
  # deadline. A staged original the writes read is pinned for the writer and
  # counted as pending against the originals cache. The write is dropped when
  # the cache runs its maximum number of writers or its pending bytes would
  # pass the limit. Without a running cache, or when the original can't be
  # pinned, the writes run in the request. At the writer limit, only the
  # original is dropped. The deadline and the writer's maximum age are guesses
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
  Publishes `write` for the source `hash` under `lease`. `write` is a
  function, or `{:staged, path, put, then}` when `put` stores the staged
  original at `path`, given the path to read, and `then`, a function or nil,
  runs after it. A dropped original still runs `then`.
  """
  def publish(hash, lease, write, opts) do
    case writers_root(opts) do
      nil -> Work.publish(hash, lease, inline(write))
      root -> hand_off(root, hash, lease, write, opts)
    end
  end

  defp hand_off(root, hash, lease, write, opts) do
    with {:ok, writer} <- Writers.start_child(root, job()),
         {:ok, run, finish} <- prepare(write, writer, root, hash, opts) do
      Work.transfer(lease, writer, @lease_deadline)
      context = RequestContext.capture()

      send(
        writer,
        {:publish, context,
         fn ->
           try do
             Work.publish(hash, lease, run)
             Work.unlock(lease)
           after
             finish.()
           end
         end}
      )

      :ok
    else
      {:error, :unavailable} ->
        Work.publish(hash, lease, inline(write))

      {:error, :writer_limit} ->
        Work.publish(hash, lease, without_original(write, hash, opts))

      {:error, :unpinned, writer} ->
        send(writer, :cancel)
        Work.publish(hash, lease, inline(write))
    end
  end

  defp prepare({:staged, path, put, then}, writer, root, hash, opts) do
    with {:ok, %{size: size}} <- File.stat(path),
         :ok <- Writers.reserve(root, size) do
      pinned(path, size, writer, root, put, then)
    else
      :full ->
        dropped(hash, :pending_limit, opts)
        {:ok, fn -> run_then(then) end, fn -> :ok end}

      {:error, _reason} ->
        {:error, :unpinned, writer}
    end
  end

  defp prepare(fun, _writer, _root, _hash, _opts), do: {:ok, fun, fn -> :ok end}

  defp pinned(path, size, writer, root, put, then) do
    case Input.pin(path) do
      {:ok, pinned, ref} ->
        Resources.transfer(ref, writer)

        finish = fn ->
          Resources.release(ref)
          Writers.release(root, size)
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
        Writers.release(root, size)
        {:error, :unpinned, writer}
    end
  end

  defp inline({:staged, path, put, then}) do
    fn ->
      put.(path)
      run_then(then)
    end
  end

  defp inline(fun), do: fun

  # Without a writer, the original isn't stored, but the writes that keep the
  # cache correct, such as an invalidation, still run in the request.
  defp without_original({:staged, _path, _put, then}, hash, opts) do
    dropped(hash, :writer_limit, opts)
    fn -> run_then(then) end
  end

  defp without_original(fun, _hash, _opts), do: fun

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
  def await do
    receive do
      {:publish, context, fun} ->
        RequestContext.adopt(context)
        fun.()

      :cancel ->
        :ok
    after
      @max_age -> :ok
    end
  end

  defp dropped(hash, reason, opts) do
    Telemetry.execute(Telemetry.telemetry_opts(opts), [:cache, :stage], %{}, %{
      result: :ok,
      cache: :stage_dropped,
      reason: reason,
      output_format: nil,
      cache_key: hash
    })
  end
end
