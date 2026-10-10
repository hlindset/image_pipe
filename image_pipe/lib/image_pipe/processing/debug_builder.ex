defmodule ImagePipe.Processing.DebugBuilder do
  @moduledoc false
  # Builds debug facts on every generation; rendering is gated at delivery.

  alias ImagePipe.Debug.Info
  alias ImagePipe.Output.Policy
  alias ImagePipe.Output.Resolved, as: ResolvedOutput
  alias ImagePipe.Processing.Prepared

  @spec build(Prepared.t(), map() | nil, non_neg_integer()) :: Info.t()
  def build(%Prepared{} = prepared, search_meta, encode_us) do
    %Prepared{geometry: geometry, resolved_output: resolved_output, state: %{image: image}} =
      prepared

    {source_width, source_height} = geometry.storage_dimensions
    facts = geometry.debug_facts

    %Info{
      source_format: geometry.source_format,
      source_bytes: Map.get(facts, :source_bytes),
      source_width: source_width,
      source_height: source_height,
      source_color_space: Map.get(facts, :source_color_space),
      source_icc?: Map.get(facts, :source_icc?),
      source_bit_depth: Map.get(facts, :source_bit_depth),
      source_alpha?: Map.get(facts, :source_alpha?),
      source_orientation: Map.get(facts, :source_orientation),
      shrink: prepared.shrink,
      output_format: resolved_output.format,
      output_negotiated?: negotiated?(prepared.policy),
      output_width: Image.width(image),
      output_height: Image.height(image),
      output_quality: output_quality(resolved_output, search_meta),
      output_stripped?: resolved_output.strip_metadata,
      output_color_profile: color_profile(resolved_output.color_profile),
      aq: aq_from_meta(resolved_output, search_meta),
      pipeline: prepared.operations,
      timings: Map.put(prepared.timings, :encode, encode_us)
    }
  end

  @spec build_terminal([atom()], non_neg_integer()) :: Info.t()
  def build_terminal(operations, total_us) do
    %Info{pipeline: operations, timings: %{total: total_us}}
  end

  defp color_profile({:convert, profile}), do: profile
  defp color_profile(policy), do: policy

  defp negotiated?(%Policy{mode: {:explicit, _format}}), do: false
  defp negotiated?(%Policy{mode: :source}), do: true

  defp output_quality(%ResolvedOutput{}, %{quality: quality})
       when is_integer(quality) and quality > 0,
       do: quality

  defp output_quality(%ResolvedOutput{quality: {:quality, quality}}, _search_meta), do: quality
  defp output_quality(%ResolvedOutput{quality: :default}, _search_meta), do: :default

  defp aq_from_meta(_resolved_output, nil), do: nil
  defp aq_from_meta(%ResolvedOutput{quality_search: :none}, _search_meta), do: nil

  defp aq_from_meta(%ResolvedOutput{quality_search: search}, %{} = metadata) do
    %{
      score: Map.get(metadata, :score),
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
end
