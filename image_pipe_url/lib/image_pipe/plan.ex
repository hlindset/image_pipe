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

  # The request controls `new/1` accepts, for generated documentation.
  @doc false
  @spec request_schema() :: keyword()
  def request_schema, do: Options.request_schema()

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

  # Rewrites each group in order, stopping at the first error.
  @doc false
  @spec map_groups(t(), (map() -> {:ok, map()} | {:error, term()})) ::
          {:ok, t()} | {:error, term()}
  def map_groups(%__MODULE__{} = plan, fun) do
    plan.groups
    |> Enum.reduce_while({:ok, []}, fn group, {:ok, groups} ->
      case fun.(group) do
        {:ok, group} -> {:cont, {:ok, [group | groups]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, groups} -> {:ok, %{plan | groups: Enum.reverse(groups)}}
      error -> error
    end
  end

  @doc false
  @spec validate(t(), map(), map() | nil) :: :ok | {:error, [Issue.t()]}
  def validate(%__MODULE__{} = plan, presets \\ %{}, defaults \\ nil) do
    case to_spec(plan, presets, defaults) do
      {:ok, _request} -> :ok
      {:error, _issues} = error -> error
    end
  end

  @doc false
  @spec to_spec(t(), map(), map() | nil, Spec.Validation.watermarks()) ::
          {:ok, Spec.t()} | {:error, [Issue.t()]}
  def to_spec(%__MODULE__{} = plan, presets \\ %{}, defaults \\ nil, watermarks \\ nil) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    with {:ok, expanded} <- Presets.expand(indexed, plan.options, presets, defaults) do
      groups = expanded.groups |> Enum.sort() |> Enum.map(&elem(&1, 1))

      case Spec.errors(groups, expanded.request, MapSet.new(), watermarks) do
        [] -> {:ok, Spec.build(groups, expanded.request)}
        issues -> {:error, issues}
      end
    end
  end

  # Referenced preset names in reading order, for request-time lookup.
  @doc false
  @spec preset_names(t()) :: [String.t()]
  def preset_names(%__MODULE__{} = plan),
    do:
      plan
      |> groups()
      |> Enum.with_index()
      |> Map.new(fn {g, i} -> {i, g} end)
      |> Presets.references()

  defp groups(%__MODULE__{groups: []}), do: [%{}]
  defp groups(%__MODULE__{groups: groups}), do: groups
end
