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
      Spec,
      Spec.Group,
      Spec.Output,
      Spec.Issue,
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
      Source.Object
    ]

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Presets
  alias ImagePipe.Plan.Spec
  alias ImagePipe.Plan.Spec.Issue

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
    case to_spec(plan, presets) do
      {:ok, _request} -> :ok
      {:error, _issues} = error -> error
    end
  end

  @doc false
  @spec to_spec(t(), map()) :: {:ok, Spec.t()} | {:error, [Issue.t()]}
  def to_spec(%__MODULE__{} = plan, presets \\ %{}) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    with {:ok, expanded} <- Presets.expand(indexed, plan.options, presets) do
      groups = expanded.groups |> Enum.sort() |> Enum.map(&elem(&1, 1))

      case Spec.errors(groups, expanded.request) do
        [] -> {:ok, Spec.build(groups, expanded.request)}
        issues -> {:error, issues}
      end
    end
  end

  defp groups(%__MODULE__{groups: []}), do: [%{}]
  defp groups(%__MODULE__{groups: groups}), do: groups
end
