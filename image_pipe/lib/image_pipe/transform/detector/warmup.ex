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

  A failed warmup, including one that raises or exits, is logged as a warning
  and retried, with exponential backoff capped at a minute, until it
  succeeds. A success after failures is logged at info level. After it
  succeeds, the worker exits normally, so `restart: :transient` does not
  restart it. Unavailable detectors are skipped, and so is a detector whose
  `available?/1` raises, with a warning. It does not trap exits; shutdown
  during a download needs no cleanup.

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

    case guarded(fn -> module.available?(opts) end) do
      true ->
        attempt(Map.merge(state, %{module: module, warmup_opts: opts, failures: 0}))

      false ->
        Logger.warning("ImagePipe detector warmup skipped: #{inspect(module)} is unavailable")
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.warning(
          "ImagePipe detector warmup skipped: #{inspect(module)}.available?/1 " <>
            "failed (#{inspect(reason)})"
        )

        {:stop, :normal, state}
    end
  end

  defp attempt(state) do
    case guarded(fn -> Detector.warmup(state.module, state.warmup_opts) end) do
      :ok ->
        if state.failures > 0 do
          Logger.info(
            "ImagePipe detector warmup succeeded for #{inspect(state.module)} " <>
              "after #{state.failures} failed #{attempts(state.failures)}"
          )
        end

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

  # The detector is the host's code. A crash here would restart the worker
  # until it took its instance down, so it counts as a failed attempt.
  defp guarded(fun) do
    fun.()
  rescue
    exception -> {:error, {:raised, Exception.message(exception)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  # The detector's options can hold credentials, such as an API key.
  @impl true
  def format_status(%{state: state} = status),
    do: %{status | state: Map.drop(state, [:opts, :warmup_opts])}

  defp attempts(1), do: "attempt"
  defp attempts(_failures), do: "attempts"

  defp backoff_ms(prior_failures) do
    min(@backoff_cap_ms, @backoff_base_ms * Integer.pow(2, min(prior_failures, 20)))
  end
end
