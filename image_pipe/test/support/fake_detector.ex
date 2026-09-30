defmodule ImagePipe.Test.FakeDetector do
  @moduledoc "Configurable in-memory Detector for deterministic tests."
  @behaviour ImagePipe.Transform.Detector

  def returning(result) do
    Process.put({__MODULE__, :result}, result)
    __MODULE__
  end

  @impl true
  def supported_classes(opts), do: Keyword.get(opts, :supported_classes, ["face"])

  @impl true
  def detect(image, opts) do
    # When `record_to` is a pid, report the dimensions of the image the detector
    # actually sees. The deferred-orientation flush must precede detection, so a
    # portrait-EXIF source (stored 40×80, displays 80×40) must report the display
    # frame {80, 40}, never the storage frame {40, 80}.
    case Keyword.get(opts, :record_to) do
      nil -> :ok
      pid when is_pid(pid) -> send(pid, {:detect_dims, Image.width(image), Image.height(image)})
    end

    Process.get({__MODULE__, :result}, {:ok, []})
  end

  @impl true
  def available?(opts), do: Keyword.get(opts, :available?, true)

  @impl true
  def identity(opts), do: {__MODULE__, Keyword.get(opts, :identity, :fake_v1)}
end
