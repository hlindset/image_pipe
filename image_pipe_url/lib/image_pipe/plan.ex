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
  @spec validate(t(), map(), map() | nil, Spec.Validation.watermarks()) ::
          {:ok, [Issue.t()]} | {:error, [Issue.t()]}
  def validate(%__MODULE__{} = plan, presets \\ %{}, defaults \\ nil, watermarks \\ nil) do
    with {:ok, request} <- to_spec(plan, presets, defaults, watermarks),
         do: {:ok, request.ignored}
  end

  @doc false
  @spec to_spec(t(), map(), map() | nil, Spec.Validation.watermarks()) ::
          {:ok, Spec.t()} | {:error, [Issue.t()]}
  def to_spec(%__MODULE__{} = plan, presets \\ %{}, defaults \\ nil, watermarks \\ nil) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    with {:ok, expanded} <- Presets.expand(indexed, plan.options, presets, defaults),
         groups = expanded.groups |> Enum.sort() |> Enum.map(&elem(&1, 1)),
         written? = &written?(&1, indexed, expanded.origins, plan.options),
         {:ok, groups, options, warnings} <-
           Spec.settle(groups, expanded.request, MapSet.new(), watermarks, written?) do
      {:ok, %{Spec.build(groups, options) | ignored: warnings}}
    end
  end

  # Whether the plan itself sets the option, rather than a preset or the
  # request defaults.
  defp written?({:group, index, key}, indexed, origins, _options),
    do: indexed |> Map.fetch!(Map.fetch!(origins, index)) |> Map.has_key?(key)

  defp written?({:request, key}, _indexed, _origins, options), do: Map.has_key?(options, key)

  # Validates a plan whose presets a request-time lookup may resolve. When the
  # plan names a preset missing from `presets`, only the groups that name no
  # such preset are checked: a missing preset can supply any option of its
  # group and of the request.
  @doc false
  @spec validate_known(t(), map(), map() | nil, Spec.Validation.watermarks()) ::
          {:ok, [Issue.t()]} | {:error, [Issue.t()]}
  def validate_known(%__MODULE__{} = plan, presets, defaults, watermarks) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    unknown =
      for {index, group} <- indexed,
          name <- Map.get(group, :presets, []),
          not Map.has_key?(presets, name),
          do: {index, name}

    case unknown do
      [] ->
        validate(plan, presets, defaults, watermarks)

      unknown ->
        validate_known_groups(indexed, plan.options, presets, defaults, watermarks, unknown)
    end
  end

  defp validate_known_groups(indexed, request, presets, defaults, watermarks, unknown) do
    stubs =
      Map.new(unknown, fn {_index, name} -> {name, %{groups: %{0 => %{}}, request: %{}}} end)

    tainted = MapSet.new(unknown, &elem(&1, 0))

    with {:ok, expanded} <-
           Presets.expand(indexed, request, Map.merge(presets, stubs), defaults) do
      groups = expanded.groups |> Enum.sort() |> Enum.map(&elem(&1, 1))

      groups
      |> Spec.errors(expanded.request, MapSet.new(), watermarks)
      |> Enum.flat_map(&in_plan_groups(&1, expanded.origins, tainted))
      |> Enum.reject(&(&1.severity == :warning and not written_in_plan?(&1, indexed)))
      |> Enum.split_with(&(&1.severity == :warning))
      |> case do
        {warnings, []} -> {:ok, warnings}
        {warnings, errors} -> {:error, errors ++ warnings}
      end
    end
  end

  # Keeps an issue only when every location is in a group without an unknown
  # preset, numbered as the plan numbers its groups.
  defp in_plan_groups(issue, origins, tainted) do
    locations =
      Enum.map(issue.locations, fn
        {:group, index, key} -> {:group, Map.fetch!(origins, index), key}
        {:request, _key} -> nil
      end)

    case Enum.all?(locations, &match?({:group, _, _}, &1)) and
           not Enum.any?(locations, fn {:group, origin, _key} -> origin in tainted end) do
      true -> [%{issue | locations: locations}]
      false -> []
    end
  end

  # Locations here are already numbered as the plan numbers its groups.
  defp written_in_plan?(issue, indexed) do
    Enum.any?(issue.locations, fn {:group, index, key} ->
      indexed |> Map.fetch!(index) |> Map.has_key?(key)
    end)
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
