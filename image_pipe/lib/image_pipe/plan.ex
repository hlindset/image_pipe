defmodule ImagePipe.Plan do
  @moduledoc """
  An immutable processing plan built through the `ImagePipe` builder API.

  Plans contain typed option values and retain explicit choices until
  validation. Each group runs in the fixed ImagePipe stage order. A plan
  contains no source, credentials, runtime configuration, or open resources.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Format],
    exports: [
      Presets,
      Request,
      Request.Group,
      Request.Output,
      Request.Issue,
      Output,
      Output.QualitySearch,
      Output.QualitySearch.Metric,
      Output.QualitySearch.Size,
      Output.QualitySearch.Ssimulacra2,
      Output.QualitySearch.Butteraugli,
      Output.JpegOptions,
      Output.PngOptions,
      Output.WebpOptions,
      Output.AvifOptions,
      Color,
      Source,
      Source.Identity,
      Source.Path,
      Source.URL,
      Source.Object,
      Source.Reference
    ]

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Presets
  alias ImagePipe.Plan.Request
  alias ImagePipe.Plan.Request.Issue

  defstruct groups: [], options: %{}

  @opaque t :: %__MODULE__{groups: [map()], options: map()}

  @doc false
  @spec new(keyword()) :: t()
  def new(options), do: %__MODULE__{options: Options.request!(options)}

  @doc false
  @spec group(t(), keyword()) :: t()
  def group(%__MODULE__{} = plan, options) do
    group = Options.group!(options)
    %{plan | groups: plan.groups ++ [group]}
  end

  @doc false
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = plan, options) do
    %{plan | options: Map.merge(plan.options, Options.output!(options))}
  end

  @doc false
  @spec validate(t(), map()) :: :ok | {:error, [Issue.t()]}
  def validate(%__MODULE__{} = plan, presets \\ %{}) do
    case to_request(plan, presets) do
      {:ok, _request} -> :ok
      {:error, _issues} = error -> error
    end
  end

  @doc false
  @spec to_request(t(), map()) :: {:ok, Request.t()} | {:error, [Issue.t()]}
  def to_request(%__MODULE__{} = plan, presets \\ %{}) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    with {:ok, expanded} <- Presets.expand(indexed, plan.options, presets) do
      groups = expanded.groups |> Enum.sort() |> Enum.map(&elem(&1, 1))

      case Request.errors(groups, expanded.request) do
        [] -> {:ok, Request.build(groups, expanded.request)}
        issues -> {:error, issues}
      end
    end
  end

  defp groups(%__MODULE__{groups: []}), do: [%{}]
  defp groups(%__MODULE__{groups: groups}), do: groups
end
