defmodule ImagePipe.Transform.Detector.ImageVision.Model do
  @moduledoc false
  # Shared by the image_vision adapters: an unavailable adapter reports its own
  # identity, so a fallback isn't cached under the working model's key.

  @spec identity(module(), boolean(), term()) :: {module(), term()}
  def identity(adapter, true, model), do: {adapter, model}
  def identity(adapter, false, _model), do: {adapter, :unavailable}

  # Workaround for `image_vision` 0.4.0: its load_model (detection.ex,
  # face_detection.ex) checks :persistent_term, downloads with
  # ModelCache.fetch! and loads with Ortex without a lock, so concurrent first
  # calls each download and load the model (beads image_plug-8qdy). Until an
  # upstream fix, `fun` runs one call at a time per adapter until one returns
  # `{:ok, _}`; later calls skip the lock. The lock is a process registered
  # under an adapter-derived name, which exits when its owner releases it or
  # dies.
  @spec first_load(module(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def first_load(adapter, fun) when is_atom(adapter) do
    if :persistent_term.get({__MODULE__, adapter}, false),
      do: fun.(),
      else: locked(adapter, fun)
  end

  defp locked(adapter, fun) do
    name = Module.concat(adapter, FirstLoad)
    lock = spawn_lock()

    if register(lock, name) do
      try do
        with {:ok, _} = result <- fun.() do
          :persistent_term.put({__MODULE__, adapter}, true)
          result
        end
      after
        send(lock, :release)
      end
    else
      send(lock, :release)
      await_release(name)
      first_load(adapter, fun)
    end
  end

  defp spawn_lock do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        :release -> :ok
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp register(lock, name) do
    Process.register(lock, name)
  rescue
    ArgumentError -> false
  end

  defp await_release(name) do
    case Process.whereis(name) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        receive do: ({:DOWN, ^ref, :process, ^pid, _reason} -> :ok)
    end
  end
end
