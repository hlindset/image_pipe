defmodule ImagePipe.Transform.Detector.Warmup do
  @moduledoc """
  One-shot worker that pre-loads a detector's models at boot.

  An `ImagePipe` instance starts it with the instance's detector and the
  classes from its `:detector_warmup` option. A configuration used without an instance,
  such as a mount configured in the router, needs the worker in the host's
  supervision tree:

      {ImagePipe.Transform.Detector.Warmup, detector: :default}

  `:detector` accepts `:default` (the bundled adapter, used when omitted), `nil`
  (no work), or a custom detector module, matching the plug option.

  A failed warmup is logged and retried, with exponential backoff capped at
  a minute, until it succeeds. The worker then exits normally, so
  `restart: :transient` does not restart it. Unavailable detectors are
  skipped. It does not trap exits; shutdown during a download needs no
  cleanup.

  Model loading runs in `handle_continue/2`, allowing `start_link/1` to return
  without waiting for the download.
  """
  use GenServer, restart: :transient

  require Logger

  alias ImagePipe.Transform
  alias ImagePipe.Transform.Detector

  # Retry delays: 100ms, 200ms, 400ms, …, capped at 60s.
  @backoff_base_ms 100
  @backoff_cap_ms 60_000

  @options_schema NimbleOptions.new!(
                    detector: [type: :atom, default: :default],
                    classes: [type: {:or, [{:in, [:all]}, {:list, :string}]}, default: :all],
                    opts: [type: :keyword_list, default: []]
                  )

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, opts} -> GenServer.start_link(__MODULE__, Map.new(opts))
      {:error, error} -> raise ArgumentError, Exception.message(error)
    end
  end

  @impl true
  def init(state), do: {:ok, state, {:continue, :warm}}

  @impl true
  def handle_continue(:warm, state) do
    case Transform.resolve_detector(state.detector) do
      nil -> {:stop, :normal, state}
      module -> start(state, module)
    end
  end

  @impl true
  def handle_info(:retry, state), do: attempt(state)

  defp start(state, module) do
    opts = Keyword.put(state.opts, :classes, state.classes)

    if module.available?(opts) do
      attempt(Map.merge(state, %{module: module, warmup_opts: opts, failures: 0}))
    else
      Logger.warning("ImagePipe detector warmup skipped: #{inspect(module)} is unavailable")
      {:stop, :normal, state}
    end
  end

  defp attempt(state) do
    case Detector.warmup(state.module, state.warmup_opts) do
      :ok ->
        {:stop, :normal, state}

      {:error, reason} ->
        delay = backoff_ms(state.failures)

        Logger.warning(
          "ImagePipe detector warmup failed (#{inspect(reason)}); retrying in #{delay} ms"
        )

        Process.send_after(self(), :retry, delay)
        {:noreply, %{state | failures: state.failures + 1}}
    end
  end

  defp backoff_ms(prior_failures) do
    min(@backoff_cap_ms, @backoff_base_ms * Integer.pow(2, min(prior_failures, 20)))
  end
end
