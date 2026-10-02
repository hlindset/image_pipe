defmodule ImagePipe.Test.DetectorFixtures.FlakyDetector do
  @moduledoc false
  # A detector whose readiness and failure are switched through
  # `:persistent_term`, because detection runs outside the test process.
  @behaviour ImagePipe.Transform.Detector

  def set(key, value), do: :persistent_term.put({__MODULE__, key}, value)
  def reset, do: Enum.each([:fail?, :ready?], &:persistent_term.erase({__MODULE__, &1}))

  @impl true
  def supported_classes(_opts), do: ["car", "face"]

  @impl true
  def available?(_opts), do: true

  @impl true
  def ready?(_opts), do: :persistent_term.get({__MODULE__, :ready?}, true)

  @impl true
  def identity(_opts), do: {__MODULE__, :v1}

  @impl true
  def detect(_image, opts) do
    if :persistent_term.get({__MODULE__, :fail?}, false) do
      {:error, {:detector, :model_crashed}}
    else
      classes = Keyword.get(opts, :classes, :all)
      label = if classes == :all, do: "car", else: List.first(classes)
      {:ok, [%{label: label, score: 0.95, box: {2, 2, 20, 20}}]}
    end
  end
end
