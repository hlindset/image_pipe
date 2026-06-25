defmodule ImagePipe.Transform.Detector.Composite do
  @moduledoc """
  A `ImagePipe.Transform.Detector` that fans a requested class set out across an
  ordered list of child detectors and merges their regions.

  Each requested class routes to the child(ren) whose `supported_classes/1` claim
  it (`:all` routes to every child); classes no child claims are dropped
  (best-effort). Identity and availability are class-aware: they reflect only the
  children a given request routes to, so e.g. an object-only request is unaffected
  by a face-model change. The bundled default composes the face (YuNet) and object
  (RT-DETR) adapters.
  """
  @behaviour ImagePipe.Transform.Detector

  alias ImagePipe.Telemetry
  alias ImagePipe.Transform.Detector
  alias ImagePipe.Transform.Detector.ImageVision

  @default_children [ImageVision.Face, ImageVision.Objects]

  @type t :: %__MODULE__{children: [module()]}
  defstruct children: @default_children

  @spec new([module()]) :: t()
  def new(children) when is_list(children), do: %__MODULE__{children: children}

  @spec default() :: t()
  def default, do: %__MODULE__{children: @default_children}

  # --- Explicit-composite helpers and Detector behaviour ---
  #
  # supported_classes/1 is shared between the behaviour (takes opts keyword)
  # and the explicit helper (takes a %Composite{} struct). The struct clause is
  # listed first so it matches before the catch-all opts clause.

  @spec supported_classes(t() | keyword()) :: [String.t()]
  def supported_classes(%__MODULE__{children: children}) do
    children |> Enum.flat_map(& &1.supported_classes([])) |> Enum.uniq()
  end

  @impl true
  def supported_classes(_opts), do: supported_classes(default())

  @impl true
  def detect(image, opts), do: detect(default(), image, opts)

  @impl true
  def available?(opts), do: available?(default(), opts)

  @impl true
  def identity(opts), do: identity(default(), opts)

  @impl true
  def warmup(opts), do: warmup(default(), opts)

  # Warm only the children the requested classes route to, so e.g.
  # `classes: ["face"]` warms YuNet but not the larger RT-DETR model. `:all`
  # (the default) warms every child.
  @spec warmup(t(), keyword()) :: :ok | {:error, term()}
  def warmup(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)

    composite
    |> routed(classes)
    |> Enum.reduce_while(:ok, fn {child, _child_classes}, _ ->
      case Detector.warmup(child, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @spec detect(t(), term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def detect(%__MODULE__{} = composite, image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    telemetry_opts = Keyword.get(opts, :telemetry_opts)

    composite
    |> routed(classes)
    |> Enum.map(fn {child, child_classes} ->
      run_child(child, child_classes, image, opts, telemetry_opts)
    end)
    |> merge_results()
  end

  # Merge the routed children's results. Any successful child yields
  # {:ok, merged regions} — best-effort across models, even if some children
  # errored or found nothing. Only when EVERY routed child errored do we surface
  # the error, so the [:transform, :detect] span reflects a real outage instead
  # of a misleading :no_regions. An empty routed set (e.g. all-unknown classes)
  # degrades to {:ok, []}.
  defp merge_results([]), do: {:ok, []}

  defp merge_results(results) do
    region_lists = for {:ok, regions} <- results, do: regions

    case region_lists do
      [] -> Enum.find(results, &match?({:error, _}, &1))
      lists -> {:ok, List.flatten(lists)}
    end
  end

  defp run_child(child, child_classes, image, opts, nil) do
    detect_child(child, child_classes, image, opts)
  end

  defp run_child(child, child_classes, image, opts, telemetry_opts) do
    start_meta = %{detector: child, model: child.identity(opts), classes: child_classes}

    Telemetry.span(telemetry_opts, [:transform, :detect, :model], start_meta, fn ->
      result = detect_child(child, child_classes, image, opts)
      {result, %{regions: region_count(result)}}
    end)
  end

  defp detect_child(child, child_classes, image, opts) do
    child.detect(image, Keyword.put(opts, :classes, child_classes))
  end

  defp region_count({:ok, regions}), do: length(regions)
  defp region_count({:error, _}), do: 0

  @spec available?(t(), keyword()) :: boolean()
  def available?(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)

    composite
    |> routed(classes)
    |> Enum.all?(fn {child, _} -> child.available?(opts) end)
  end

  @spec identity(t(), keyword()) :: {module(), [term()]}
  def identity(%__MODULE__{} = composite, opts) do
    classes = Keyword.get(opts, :classes, :all)
    ids = composite |> routed(classes) |> Enum.map(fn {child, _} -> child.identity(opts) end)
    {__MODULE__, ids}
  end

  # Returns [{child_module, child_classes}] for the children that the requested
  # class set routes to, preserving the fixed child order. `:all` -> every child
  # gets `:all`. A class list -> each child gets the intersection with its
  # supported set, and children with an empty intersection are dropped.
  defp routed(%__MODULE__{children: children}, :all) do
    Enum.map(children, &{&1, :all})
  end

  defp routed(%__MODULE__{children: children}, classes) when is_list(classes) do
    requested = MapSet.new(classes)

    children
    |> Enum.map(fn child ->
      # Routing uses each detector's STATIC vocabulary, so `[]` opts here is
      # deliberate (not a dropped argument): `supported_classes/1` must answer
      # without request-specific opts or a loaded model.
      child_classes = Enum.filter(child.supported_classes([]), &MapSet.member?(requested, &1))
      {child, child_classes}
    end)
    |> Enum.reject(fn {_child, child_classes} -> child_classes == [] end)
  end
end
