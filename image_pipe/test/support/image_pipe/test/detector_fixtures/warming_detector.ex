defmodule ImagePipe.Test.DetectorFixtures.WarmingDetector do
  @moduledoc false
  # Ready only after `warmup/1` runs. Warmup reports its classes to the process
  # registered as this module, so a test can wait for it.
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face"]

  @impl true
  def detect(_image, _opts), do: {:ok, []}

  @impl true
  def available?(_opts), do: true

  @impl true
  def ready?(_opts), do: :persistent_term.get({__MODULE__, :ready?}, false)

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def warmup(opts) do
    :persistent_term.put({__MODULE__, :ready?}, true)
    if pid = Process.whereis(__MODULE__), do: send(pid, {:warmed, opts[:classes]})
    :ok
  end

  def reset, do: :persistent_term.erase({__MODULE__, :ready?})
end
