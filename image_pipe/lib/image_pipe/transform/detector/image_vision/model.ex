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
  # upstream fix, `probe` runs one call at a time per adapter until one returns
  # `{:ok, _}`; later calls return `:ok` at once. The probe must not depend on
  # a request's image, since its error goes to every call waiting on it. The
  # lock is a process registered under an adapter-derived name, which exits
  # when its owner releases it or dies. A release exits with a failed probe's
  # error, so the calls waiting on it return that error instead of each
  # trying again in turn.
  @spec ensure_loaded(module(), (-> {:ok, term()} | {:error, term()})) :: :ok | {:error, term()}
  def ensure_loaded(adapter, probe) when is_atom(adapter) do
    if :persistent_term.get({__MODULE__, adapter}, false),
      do: :ok,
      else: locked(adapter, probe)
  end

  defp locked(adapter, probe) do
    name = Module.concat(adapter, FirstLoad)
    lock = spawn_lock()

    if register(lock, name) do
      result =
        try do
          probe.()
        catch
          kind, reason ->
            send(lock, {:release, nil})
            :erlang.raise(kind, reason, __STACKTRACE__)
        end

      case result do
        {:ok, _loaded} ->
          :persistent_term.put({__MODULE__, adapter}, true)
          send(lock, {:release, nil})
          :ok

        {:error, _reason} = error ->
          send(lock, {:release, error})
          error
      end
    else
      send(lock, {:release, nil})

      case await_release(name) do
        {:error, _reason} = error -> error
        nil -> ensure_loaded(adapter, probe)
      end
    end
  end

  defp spawn_lock do
    owner = self()

    spawn(fn ->
      ref = Process.monitor(owner)

      receive do
        {:release, result} -> exit({:shutdown, {:released, result}})
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    end)
  end

  defp register(lock, name) do
    Process.register(lock, name)
  rescue
    ArgumentError -> false
  end

  # The released probe's error, or nil when the lock went without one.
  defp await_release(name) do
    case Process.whereis(name) do
      nil ->
        nil

      pid ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, {:shutdown, {:released, result}}} -> result
          {:DOWN, ^ref, :process, ^pid, _reason} -> nil
        end
    end
  end
end
