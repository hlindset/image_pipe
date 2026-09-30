defmodule ImagePipe.Transform.DetectorTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector

  defmodule WithWarmup do
    @behaviour Detector
    @impl true
    def supported_classes(_o), do: ["face"]
    @impl true
    def detect(_i, _o), do: {:ok, []}
    @impl true
    def available?(_o), do: true
    @impl true
    def identity(_o), do: {__MODULE__, :v}
    @impl true
    def warmup(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:warmed, opts})
      :ok
    end
  end

  defmodule NoWarmup do
    @behaviour Detector
    @impl true
    def supported_classes(_o), do: ["face"]
    @impl true
    def detect(_i, _o), do: {:ok, []}
    @impl true
    def available?(_o), do: true
    @impl true
    def identity(_o), do: {__MODULE__, :v}
  end

  test "calls warmup/1 when the detector implements it" do
    assert Detector.warmup(WithWarmup, test_pid: self()) == :ok
    assert_receive {:warmed, _opts}
  end

  test "is a no-op :ok when the detector does not implement warmup/1" do
    assert Detector.warmup(NoWarmup, []) == :ok
  end
end
