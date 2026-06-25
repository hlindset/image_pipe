defmodule ImagePipe.Debug.Headers do
  @moduledoc """
  Pure rendering of `ImagePipe.Debug.Info` into the opt-in `X-ImagePipe-*` debug
  response headers and the standard `Server-Timing` header. This module is the
  single source of truth for debug header names. `nil` facts are omitted.
  """

  alias ImagePipe.Debug.Info

  @stage_order [:decode, :transform, :encode, :cache, :total]

  @doc """
  Renders the debug headers for `info`.

  Options:
    * `:accept` — the request `Accept` header value (string), rendered as
      `x-imagepipe-output-accept`. Omitted when empty/nil.
    * `:cache` — `:hit` or `:miss`, rendered as `x-imagepipe-cache`.
    * `:cache_serve_us` — when serving from cache, the live cache-read duration
      in microseconds, appended to `Server-Timing` as `cache;dur=…` (Plan 2).
  """
  @spec render(Info.t(), keyword()) :: [{String.t(), String.t()}]
  def render(%Info{} = info, opts) do
    accept = Keyword.get(opts, :accept)
    cache = Keyword.get(opts, :cache, :miss)
    cache_serve_us = Keyword.get(opts, :cache_serve_us)

    (source_headers(info) ++
       output_headers(info, accept) ++
       aq_headers(info.aq) ++
       pipeline_headers(info) ++
       cache_headers(cache) ++
       server_timing(info.timings, cache_serve_us))
    |> Enum.reject(&is_nil/1)
  end

  defp source_headers(%Info{} = info) do
    [
      kv("x-imagepipe-source-format", info.source_format),
      kv("x-imagepipe-source-size", info.source_bytes),
      kv("x-imagepipe-source-width", info.source_width),
      kv("x-imagepipe-source-height", info.source_height),
      kv("x-imagepipe-source-color-space", info.source_color_space),
      kv("x-imagepipe-source-icc", info.source_icc?),
      kv("x-imagepipe-source-bit-depth", info.source_bit_depth),
      kv("x-imagepipe-source-alpha", info.source_alpha?),
      kv("x-imagepipe-source-orientation", info.source_orientation),
      shrink_header(info.shrink)
    ]
  end

  defp output_headers(%Info{} = info, accept) do
    [
      kv("x-imagepipe-output-format", info.output_format),
      kv("x-imagepipe-output-negotiated", info.output_negotiated?),
      kv("x-imagepipe-output-accept", accept),
      kv("x-imagepipe-output-width", info.output_width),
      kv("x-imagepipe-output-height", info.output_height),
      kv("x-imagepipe-output-quality", quality_value(info.output_quality)),
      kv("x-imagepipe-output-stripped", info.output_stripped?),
      kv("x-imagepipe-output-color-profile", info.output_color_profile),
      kv("x-imagepipe-output-distance", info.output_distance)
    ]
  end

  defp aq_headers(nil), do: []

  defp aq_headers(%{} = aq) do
    [
      kv("x-imagepipe-aq-metric", Map.get(aq, :metric)),
      kv("x-imagepipe-aq-score", Map.get(aq, :score)),
      kv("x-imagepipe-aq-target", Map.get(aq, :target)),
      kv("x-imagepipe-aq-quality-min", Map.get(aq, :min)),
      kv("x-imagepipe-aq-quality-max", Map.get(aq, :max)),
      kv("x-imagepipe-aq-iterations", Map.get(aq, :iterations)),
      kv("x-imagepipe-aq-outcome", Map.get(aq, :outcome)),
      kv("x-imagepipe-aq-limiting-factor", Map.get(aq, :limiting_factor)),
      kv("x-imagepipe-aq-scorer", Map.get(aq, :scorer)),
      kv("x-imagepipe-aq-tiles", Map.get(aq, :tiles))
    ]
  end

  defp pipeline_headers(%Info{pipeline: []}), do: []

  defp pipeline_headers(%Info{pipeline: ops}),
    do: [kv("x-imagepipe-pipeline", Enum.join(ops, ","))]

  defp cache_headers(cache), do: [kv("x-imagepipe-cache", cache)]

  defp server_timing(timings, cache_serve_us) do
    entries =
      @stage_order
      |> Enum.map(fn stage ->
        timing_entry(stage, timing_value(stage, timings, cache_serve_us))
      end)
      |> Enum.reject(&is_nil/1)

    case entries do
      [] -> [nil]
      entries -> [{"server-timing", Enum.join(entries, ", ")}]
    end
  end

  defp timing_value(:cache, _timings, cache_serve_us), do: cache_serve_us
  defp timing_value(stage, timings, _cache_serve_us), do: Map.get(timings, stage)

  defp timing_entry(_stage, nil), do: nil
  defp timing_entry(stage, us), do: "#{stage};dur=#{ms(us)}"

  defp ms(us), do: Float.round(us / 1000, 3)

  defp shrink_header(nil), do: nil
  defp shrink_header(%{w: w, h: h}), do: {"x-imagepipe-shrink", "w=#{w};h=#{h}"}

  defp quality_value(:default), do: nil
  defp quality_value(value), do: value

  # An absent value (nil) or an empty string omits the header. Only the echoed
  # request Accept can be "" (every other fact is an atom/boolean/number).
  defp kv(_name, nil), do: nil
  defp kv(_name, ""), do: nil
  defp kv(name, value), do: {name, to_string(value)}
end
