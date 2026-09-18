defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  Optional one-shot worker that pre-loads a detector's models at boot.

  Add it to the host's supervision tree; ImagePipe does not start it:

      {ImagePipe.Transform.Detector.Warmup, detector: :default}

  `:detector` accepts `:default` (the bundled adapter, used when omitted), `nil`
  (no work), or a custom detector module, matching the plug option.

  Failed warmup results are logged and retried with bounded exponential backoff.
  The worker then exits normally, so `restart: :transient` does not restart it.
  Unavailable detectors are skipped. It does not trap exits; shutdown during a
  download needs no cleanup.

  Model loading runs in `handle_continue/2`, allowing `start_link/1` to return
  without waiting for the download.
  """
  use GenServer, restart: :transient

  require Logger

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector

  # Retry delays: 100ms, 200ms, 400ms, …, capped at 1s.
  @backoff_base_ms 100
  @backoff_cap_ms 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    state = %{
      detector: Keyword.get(opts, :detector, :default),
      classes: Keyword.get(opts, :classes, :all),
      opts: Keyword.get(opts, :opts, []),
      retries: Keyword.get(opts, :retries, 2)
    }

    {:ok, state, {:continue, :warm_then_stop}}
  end

  @impl true
  def handle_continue(:warm_then_stop, state) do
    case Transform.resolve_detector(state.detector) do
      nil -> :ok
      module -> warm(state, module, state.retries)
    end

    {:stop, :normal, state}
  end

  defp warm(state, module, retries) do
    opts = Keyword.put(state.opts, :classes, state.classes)

    if module.available?(opts) do
      attempt(state, module, opts, retries)
    else
      Logger.warning("ImagePipe detector warmup skipped: #{inspect(module)} is unavailable")
      :ok
    end
  end

  defp attempt(_state, _module, _opts, retries) when retries < 0, do: :ok

  defp attempt(state, module, opts, retries) do
    case Detector.warmup(module, opts) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "ImagePipe detector warmup failed (#{inspect(reason)}); #{retries} retries left"
        )

        if retries > 0, do: Process.sleep(backoff_ms(state.retries - retries))
        attempt(state, module, opts, retries - 1)
    end
  end

  defp backoff_ms(prior_failures) do
    min(@backoff_cap_ms, @backoff_base_ms * Integer.pow(2, prior_failures))
  end
end
