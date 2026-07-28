defmodule ImagePipe.Plug.DebugBuilder do
  @moduledoc false
  # The default neutral Debug.Info builder (design decision U13). Runs
  # unconditionally on every generation; rendering is gated at delivery.

  alias ImagePipe.Debug.Info
  alias ImagePipe.Dialect.DebugContext
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput

  @spec build(DebugContext.t()) :: Info.t()
  def build(%DebugContext{} = ctx), do: default(ctx)

  defp default(%DebugContext{} = ctx) do
    {source_width, source_height} = ctx.geometry.storage_dimensions
    facts = ctx.geometry.debug_facts

    %Info{
      source_format: ctx.geometry.source_format,
      source_bytes: Map.get(facts, :source_bytes),
      source_width: source_width,
      source_height: source_height,
      source_color_space: Map.get(facts, :source_color_space),
      source_icc?: Map.get(facts, :source_icc?),
      source_bit_depth: Map.get(facts, :source_bit_depth),
      source_alpha?: Map.get(facts, :source_alpha?),
      source_orientation: Map.get(facts, :source_orientation),
      shrink: ctx.shrink,
      output_format: ctx.resolved_output.format,
      output_negotiated?: negotiated?(ctx.negotiation.policy),
      output_width: Image.width(ctx.image),
      output_height: Image.height(ctx.image),
      output_quality: output_quality(ctx.resolved_output, ctx.search_meta),
      output_stripped?: ctx.resolved_output.strip_metadata,
      output_color_profile: ctx.resolved_output.color_profile,
      output_distance: output_distance(ctx.resolved_output),
      aq: aq_from_meta(ctx.resolved_output, ctx.search_meta),
      pipeline: ctx.operations,
      timings: ctx.timings
    }
  end

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%ResolvedOutput{}, %{quality: quality})
       when is_integer(quality) and quality > 0,
       do: quality

  defp output_quality(%ResolvedOutput{quality: {:quality, quality}}, _search_meta), do: quality
  defp output_quality(%ResolvedOutput{quality: :default}, _search_meta), do: :default

  defp output_distance(%ResolvedOutput{quality_search: :none}), do: nil

  defp output_distance(%ResolvedOutput{quality_search: %module{target: target}})
       when is_number(target) do
    case native_jxl_search?(module) do
      true -> target
      false -> nil
    end
  end

  defp output_distance(%ResolvedOutput{}), do: nil

  defp aq_from_meta(_resolved_output, nil), do: nil
  defp aq_from_meta(%ResolvedOutput{quality_search: :none}, _search_meta), do: nil

  defp aq_from_meta(%ResolvedOutput{quality_search: %module{} = search}, %{} = metadata) do
    metric = quality_search_metric(module)

    %{
      metric: metric,
      score: quality_search_score(module, metadata),
      target: Map.get(search, :target),
      min: Map.get(search, :min_quality),
      max: Map.get(search, :max_quality),
      iterations: Map.get(metadata, :iterations),
      outcome: Map.get(metadata, :outcome),
      limiting_factor: Map.get(metadata, :limiting_factor),
      scorer: Map.get(metadata, :scorer),
      tiles: Map.get(metadata, :tiles_scored)
    }
  end

  defp quality_search_score(module, metadata) do
    case native_jxl_search?(module) do
      true -> nil
      false -> Map.get(metadata, :score)
    end
  end

  defp quality_search_metric(module) do
    case module |> Module.split() |> List.last() do
      "Ssimulacra2" -> :ssimulacra2
      "Butteraugli" -> :butteraugli
      "NativeJxlButteraugli" -> :butteraugli
      "Size" -> :size
      _other -> nil
    end
  end

  defp native_jxl_search?(module),
    do: module |> Module.split() |> List.last() == "NativeJxlButteraugli"
end
