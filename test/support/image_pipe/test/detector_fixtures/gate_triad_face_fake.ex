defmodule ImagePipe.Test.DetectorFixtures.GateTriadFaceFake do
  @moduledoc false
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_), do: ["face"]

  @impl true
  def available?(_), do: true

  @impl true
  def identity(_), do: {__MODULE__, :face_v1}

  @impl true
  def detect(_image, opts) do
    {:ok, [%{label: "face", score: 0.9, box: {0, 0, 50, 50}}]}
    |> filter_classes(Keyword.get(opts, :classes, :all))
  end

  defp filter_classes({:ok, regions}, :all), do: {:ok, regions}

  defp filter_classes({:ok, regions}, classes) when is_list(classes) do
    wanted = MapSet.new(classes)
    {:ok, Enum.filter(regions, fn %{label: label} -> MapSet.member?(wanted, label) end)}
  end
end
