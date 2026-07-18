defmodule ImagePipe.Dialect.TwicPics.Output do
  @moduledoc false

  alias ImagePipe.Plan.Output, as: PlanOutput

  @formats %{"auto" => :auto, "avif" => :avif, "webp" => :webp, "jpeg" => :jpeg, "png" => :png}

  @spec format(String.t()) :: {:ok, atom()} | {:error, term()}
  # ex_dna:disable-for-next-line
  def format(value) do
    case Map.fetch(@formats, value) do
      {:ok, format} -> {:ok, format}
      :error -> {:error, {:unsupported_output, value}}
    end
  end

  @spec quality(String.t()) :: {:ok, {:quality, 1..100}} | {:error, term()}
  # ex_dna:disable-for-next-line
  def quality(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..100 -> {:ok, {:quality, n}}
      _ -> {:error, {:invalid_quality, value}}
    end
  end

  @spec build(%{format: atom(), quality: PlanOutput.quality()}) :: {:ok, PlanOutput.t()}
  # ex_dna:disable-for-next-line
  def build(%{format: :auto, quality: quality}),
    do: {:ok, %PlanOutput{mode: :automatic, quality: quality}}

  def build(%{format: format, quality: quality}),
    do: {:ok, %PlanOutput{mode: {:explicit, format}, quality: quality}}
end
