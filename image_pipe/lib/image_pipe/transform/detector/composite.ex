defmodule ImagePipe.Transform.Detector.Composite do
  @moduledoc """
  Routes requested classes to an ordered list of detectors and merges their regions.

  Each class goes to every child that lists it in `supported_classes/1`; `:all`
  routes to every child, and unclaimed classes are dropped. Identity and
  availability reflect only routed children, so an object-only request is
  unaffected by a face-model change. A failing child fails the detection.

  An unavailable child contributes no regions, and the other children's
  regions are used. A child must return a different identity while it is
  unavailable (see "Identity" in `ImagePipe.Transform.Detector`), so that
  result is cached under its own key and replaced once the child is
  available again. When every routed child is unavailable, the composite
  returns `{:error, {:detector, :unavailable}}`. With `detector_required:
  true`, any unavailable routed child fails the request with `501` instead.

  The default combines the face (YuNet) and object (RT-DETR) adapters.
  """
  @behaviour ImagePipe.Transform.Detector

  alias ImagePipe.Telemetry
  alias ImagePipe.Telemetry.RequestContext
  alias ImagePipe.Transform.Detector
  alias ImagePipe.Transform.Detector.ImageVision

  @default_children [ImageVision.Face, ImageVision.Objects]

  @impl true
  def supported_classes(_opts), do: children_classes(@default_children)

  @impl true
  def detect(image, opts), do: detect(@default_children, image, opts)

  @impl true
  def available?(opts), do: available?(@default_children, opts)

  @impl true
  def identity(opts), do: identity(@default_children, opts)

  @impl true
  def ready?(opts), do: ready?(@default_children, opts)

  @impl true
  def warmup(opts), do: warmup(@default_children, opts)

  # The functions below take the child detectors explicitly, in order. The
  # callbacks above pass the default children.

  @doc false
  @spec children_classes([module()]) :: [String.t()]
  def children_classes(children) do
    children |> Enum.flat_map(& &1.supported_classes([])) |> Enum.uniq()
  end

  # Warm only the children the requested classes route to, so e.g.
  # `classes: ["face"]` warms YuNet but not the larger RT-DETR model. `:all`
  # (the default) warms every child.
  @doc false
  @spec warmup([module()], keyword()) :: :ok | {:error, term()}
  def warmup(children, opts) do
    classes = Keyword.get(opts, :classes, :all)

    children
    |> routed(classes)
    |> Enum.reduce_while(:ok, fn {child, _child_classes}, _ ->
      case Detector.warmup(child, opts) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  @doc false
  @spec detect([module()], term(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def detect(children, image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    telemetry_opts = Keyword.get(opts, :telemetry_opts)

    children
    |> routed(classes)
    |> run_children(image, opts, telemetry_opts)
    |> merge_results()
  end

  # Children are independent models, so two or more run in their own processes,
  # each carrying the request's trace context and Logger metadata. Results keep
  # the child order.
  defp run_children([{child, child_classes}], image, opts, telemetry_opts) do
    [run_child(child, child_classes, image, opts, telemetry_opts)]
  end

  defp run_children(routed, image, opts, telemetry_opts) do
    context = RequestContext.capture()

    routed
    |> Task.async_stream(
      fn {child, child_classes} ->
        RequestContext.adopt(context)
        run_child(child, child_classes, image, opts, telemetry_opts)
      end,
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
  end

  # Any child error other than an unavailable child fails the detection, so the
  # caller never treats a partial result as complete. An unavailable child
  # contributes no regions. Every child unavailable is an unavailable detector.
  # No routed children yields {:ok, []}.
  defp merge_results([]), do: {:ok, []}

  defp merge_results(results) do
    failure =
      Enum.find(results, fn
        {:error, {:detector, :unavailable}} -> false
        result -> match?({:error, _}, result)
      end)

    case {failure, for({:ok, regions} <- results, do: regions)} do
      {{:error, _} = error, _lists} -> error
      {nil, []} -> {:error, {:detector, :unavailable}}
      {nil, lists} -> {:ok, List.flatten(lists)}
    end
  end

  defp run_child(child, child_classes, image, opts, nil) do
    detect_child(child, child_classes, image, opts)
  end

  defp run_child(child, child_classes, image, opts, telemetry_opts) do
    start_meta = %{detector: child, model: child.identity(opts), classes: child_classes}

    Telemetry.span(telemetry_opts, [:transform, :detect, :model], start_meta, fn ->
      result = detect_child(child, child_classes, image, opts)
      {result, result_metadata(result)}
    end)
  end

  defp detect_child(child, child_classes, image, opts) do
    child.detect(image, Keyword.put(opts, :classes, child_classes))
  end

  defp result_metadata({:ok, regions}), do: %{result: :ok, regions: length(regions)}
  defp result_metadata({:error, _}), do: %{result: :error, regions: 0}

  @doc false
  @spec available?([module()], keyword()) :: boolean()
  def available?(children, opts) do
    classes = Keyword.get(opts, :classes, :all)

    children
    |> routed(classes)
    |> Enum.all?(fn {child, _} -> child.available?(opts) end)
  end

  @doc false
  @spec ready?([module()], keyword()) :: boolean()
  def ready?(children, opts) do
    classes = Keyword.get(opts, :classes, :all)

    children
    |> routed(classes)
    |> Enum.all?(fn {child, _} -> Detector.ready?(child, opts) end)
  end

  @doc false
  @spec identity([module()], keyword()) :: {module(), [term()]}
  def identity(children, opts) do
    classes = Keyword.get(opts, :classes, :all)
    ids = children |> routed(classes) |> Enum.map(fn {child, _} -> child.identity(opts) end)
    {__MODULE__, ids}
  end

  # Returns [{child_module, child_classes}] for the children that the requested
  # class set routes to, preserving the fixed child order. `:all` -> every child
  # gets `:all`. A class list -> each child gets the intersection with its
  # supported set, and children with an empty intersection are dropped.
  defp routed(children, :all) do
    Enum.map(children, &{&1, :all})
  end

  defp routed(children, classes) when is_list(classes) do
    requested = MapSet.new(classes)

    children
    |> Enum.map(fn child ->
      # Routing uses static vocabulary, independent of request options or model loading.
      child_classes = Enum.filter(child.supported_classes([]), &MapSet.member?(requested, &1))
      {child, child_classes}
    end)
    |> Enum.reject(fn {_child, child_classes} -> child_classes == [] end)
  end
end
