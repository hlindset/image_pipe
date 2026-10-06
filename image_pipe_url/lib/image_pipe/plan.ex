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

  # `issues` holds the builder's own findings: options it rejected, and
  # mistakes it repaired. `rejected` holds each rejected option's location
  # and value, so a URL can still be written with them. `output/2` keeps its
  # own in `output_issues` and `output_rejected`, which a later call
  # replaces option by option.
  defstruct groups: [],
            options: %{},
            issues: [],
            rejected: [],
            output_issues: [],
            output_rejected: []

  @opaque t :: %__MODULE__{
            groups: [map()],
            options: map(),
            issues: [Issue.t()],
            rejected: [{Issue.location(), term()}],
            output_issues: [Issue.t()],
            output_rejected: [{Issue.location(), term()}]
          }

  @doc false
  @spec new(keyword()) :: t()
  def new(options) do
    {options, issues, rejected} = Options.request(options)
    %__MODULE__{options: options, issues: issues, rejected: rejected}
  end

  # The request controls `new/1` accepts, for generated documentation.
  @doc false
  @spec request_schema() :: keyword()
  def request_schema, do: Options.request_schema()

  @doc false
  @spec group(t(), keyword()) :: t()
  def group(%__MODULE__{} = plan, options) do
    case Options.group(options, length(plan.groups)) do
      {:empty, issues, []} ->
        empty = %Issue{reason: :empty_group, locations: [], detail: nil, severity: :warning}
        %{plan | issues: plan.issues ++ issues ++ [empty]}

      {group, issues, rejected} ->
        %{
          plan
          | groups: plan.groups ++ [group],
            issues: plan.issues ++ issues,
            rejected: plan.rejected ++ rejected
        }
    end
  end

  @doc false
  @spec output(t(), keyword()) :: t()
  def output(%__MODULE__{} = plan, options) do
    {values, issues, rejected} = Options.output(options)
    given = options |> Keyword.keys() |> Enum.filter(&Options.output_option?/1)
    given? = &(elem(&1, 1) in given)

    # An option given again replaces its earlier value, and any mistake an
    # earlier output/2 call recorded for it.
    %{
      plan
      | options: plan.options |> Map.drop(given) |> Map.merge(values),
        output_issues:
          Enum.reject(plan.output_issues, &Enum.any?(&1.locations, given?)) ++ issues,
        output_rejected: Enum.reject(plan.output_rejected, &given?.(elem(&1, 0))) ++ rejected
    }
  end

  # Replaces the value of each rejected `key` option with an empty string.
  @doc false
  @spec blank_rejected(t(), atom()) :: t()
  def blank_rejected(%__MODULE__{} = plan, key) do
    blank =
      &Enum.map(&1, fn {location, value} ->
        if elem(location, tuple_size(location) - 1) == key,
          do: {location, ""},
          else: {location, value}
      end)

    %{plan | rejected: blank.(plan.rejected), output_rejected: blank.(plan.output_rejected)}
  end

  # The builder's own issues: `{:ok, warnings}`, or `{:error, issues}` with
  # the errors first.
  @doc false
  @spec built(t()) :: {:ok, [Issue.t()]} | {:error, [Issue.t()]}
  def built(%__MODULE__{} = plan), do: split(plan.issues ++ plan.output_issues)

  defp split(issues) do
    case Enum.split_with(issues, &(&1.severity == :warning)) do
      {warnings, []} -> {:ok, warnings}
      {warnings, errors} -> {:error, errors ++ warnings}
    end
  end

  # Adds the builder's warnings to a check's result.
  defp with_built(%__MODULE__{} = plan, check) do
    with {:ok, warnings} <- built(plan) do
      case check.() do
        {:ok, more} -> {:ok, warnings ++ more}
        {:error, issues} -> split(issues ++ warnings)
      end
    end
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
    with_built(plan, fn ->
      with {:ok, request} <- spec(plan, presets, defaults, watermarks),
           do: {:ok, request.ignored}
    end)
  end

  @doc false
  @spec to_spec(t(), map(), map() | nil, Spec.Validation.watermarks()) ::
          {:ok, Spec.t()} | {:error, [Issue.t()]}
  def to_spec(%__MODULE__{} = plan, presets \\ %{}, defaults \\ nil, watermarks \\ nil) do
    with {:ok, _warnings} <- built(plan), do: spec(plan, presets, defaults, watermarks)
  end

  defp spec(plan, presets, defaults, watermarks) do
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
  def validate_known(%__MODULE__{} = plan, presets, defaults, watermarks),
    do: with_built(plan, fn -> known(plan, presets, defaults, watermarks) end)

  defp known(plan, presets, defaults, watermarks) do
    indexed = plan |> groups() |> Enum.with_index() |> Map.new(fn {group, i} -> {i, group} end)

    unknown =
      for {index, group} <- indexed,
          name <- Map.get(group, :presets, []),
          not Map.has_key?(presets, name),
          do: {index, name}

    case unknown do
      [] ->
        with {:ok, request} <- spec(plan, presets, defaults, watermarks),
             do: {:ok, request.ignored}

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

      # Every location counts as written here; the plan's own are kept once
      # locations are numbered as the plan numbers its groups.
      checked = fn issues ->
        issues
        |> Enum.flat_map(&in_plan_groups(&1, expanded.origins, tainted))
        |> Enum.flat_map(&written_in_plan(&1, indexed))
      end

      groups
      |> Spec.settle(expanded.request, MapSet.new(), watermarks, &any_location/1)
      |> known_result(checked)
    end
  end

  defp any_location(_location), do: true

  defp known_result({:ok, _groups, _options, warnings}, checked), do: {:ok, checked.(warnings)}

  defp known_result({:error, issues}, checked) do
    case Enum.split_with(checked.(issues), &(&1.severity == :warning)) do
      {warnings, []} -> {:ok, warnings}
      {warnings, errors} -> {:error, errors ++ warnings}
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

  # Keeps a warning's locations that the plan sets itself. Locations here are
  # already numbered as the plan numbers its groups.
  defp written_in_plan(%Issue{severity: :warning} = issue, indexed) do
    case Enum.filter(issue.locations, fn {:group, index, key} ->
           indexed |> Map.fetch!(index) |> Map.has_key?(key)
         end) do
      [] -> []
      locations -> [%{issue | locations: locations}]
    end
  end

  defp written_in_plan(issue, _indexed), do: [issue]

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
