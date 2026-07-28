defmodule ImagePipe.Dialect.TwicPics.Source do
  @moduledoc false

  alias ImagePipe.Plan.Source.Path, as: SourcePath

  @spec from_segments([String.t()]) :: {:ok, SourcePath.t()} | {:error, term()}
  def from_segments([]), do: {:error, :invalid_source_path}

  def from_segments(segments) do
    if Enum.any?(segments, &(&1 == "")) do
      {:error, :invalid_source_path}
    else
      decode(segments)
    end
  end

  defp decode(segments) do
    decoded = Enum.map(segments, &URI.decode/1)
    {:ok, %SourcePath{segments: decoded}}
  end
end
