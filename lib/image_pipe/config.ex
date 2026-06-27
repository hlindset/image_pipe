defmodule ImagePipe.Config do
  @moduledoc """
  Product-neutral plan/output configuration: the schema, ImagePipe's default
  values, and the shared range checks for every tunable that is not specific to
  a dialect (imgproxy/IIIF/TwicPics). Dialect adapters validate their own keys and
  delegate the neutral keys here, so the whole plan/output layer is host-tunable
  from one schema and a drop-in provider inherits sensible defaults.

  The schema carries types only — **no `default:`**. Defaults live in
  `@scalar_defaults`/`@map_defaults`/`@default_jxl_effort` and are applied by
  `resolve!/2`, so a key can be validated without being force-defaulted
  (`jxl_effort`, whose default `Output` applies via `default/1`).
  """

  use Boundary, top_level?: true, deps: [ImagePipe.Format, ImagePipe.Plan], exports: []

  alias ImagePipe.Plan.Output.QualitySearch.Metric

  @neutral_schema_kw [
    auto_rotate: [type: :boolean],
    strip_metadata: [type: :boolean],
    keep_copyright: [type: :boolean],
    quality: [type: :pos_integer],
    format_quality: [type: {:map, :atom, :pos_integer}],
    strip_color_profile: [type: :boolean],
    preserve_hdr: [type: :boolean],
    smart_crop_face_detection: [type: :boolean],
    autoquality_method: [type: {:in, [:none, :size, :ssimulacra2, :butteraugli]}],
    autoquality_target: [type: {:map, :atom, {:or, [:integer, :float]}}],
    autoquality_min_quality: [type: :pos_integer],
    autoquality_max_quality: [type: :pos_integer],
    autoquality_allowed_error: [type: {:map, :atom, {:or, [:integer, :float]}}],
    autoquality_format_min_quality: [type: {:map, :atom, :pos_integer}],
    autoquality_format_max_quality: [type: {:map, :atom, :pos_integer}],
    autoquality_max_resolution: [type: :non_neg_integer],
    autoquality_max_iterations: [type: :pos_integer],
    jxl_effort: [type: {:in, 1..9}]
  ]

  @schema NimbleOptions.new!(@neutral_schema_kw)
  @keys Keyword.keys(@neutral_schema_kw)

  # Defaults applied by resolve! (the parser bakes these into the Plan).
  @scalar_defaults [
    auto_rotate: true,
    strip_metadata: true,
    keep_copyright: true,
    strip_color_profile: true,
    preserve_hdr: false,
    smart_crop_face_detection: false,
    quality: 80,
    autoquality_method: :none,
    autoquality_min_quality: 70,
    autoquality_max_quality: 80,
    autoquality_max_resolution: 0,
    autoquality_max_iterations: 6
  ]

  @map_defaults [
    format_quality: %{webp: 79, avif: 63, jpeg_xl: 77},
    autoquality_target: %{},
    autoquality_allowed_error: %{},
    autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
    autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80}
  ]

  # jxl_effort is NOT applied by resolve! (Output resolves it from default/1); 7 is
  # libvips jxlsave's own default, so seeding 7 is byte-neutral vs emitting no effort.
  @default_jxl_effort 7

  @all_defaults @scalar_defaults ++ @map_defaults ++ [jxl_effort: @default_jxl_effort]
  @map_keys Keyword.keys(@map_defaults)

  @doc "The neutral schema (types only)."
  @spec schema() :: NimbleOptions.t()
  def schema, do: @schema

  @doc "The neutral config keys (adapters split neutral vs dialect opts with this)."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc "ImagePipe's neutral default for a key."
  @spec default(atom()) :: term()
  def default(key), do: Keyword.fetch!(@all_defaults, key)

  @doc """
  Validate + resolve a host's neutral config against the three-layer chain
  (`defaults ← overlay ← host`). Returns a keyword of concrete neutral values,
  range-checked. `jxl_effort` is validated-if-present but not defaulted here.
  Raises `ArgumentError` on invalid input.
  """
  @spec resolve!(keyword(), keyword()) :: keyword()
  def resolve!(host_opts, overlay \\ []) when is_list(host_opts) and is_list(overlay) do
    host = validate_input!(host_opts)
    ov = validate_input!(overlay)

    resolved =
      (@scalar_defaults ++ @map_defaults)
      |> layer(ov)
      |> layer(host)

    range_check!(resolved)
    resolved
  end

  defp validate_input!(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        validated

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError, "invalid config: #{Exception.message(error)}"
    end
  end

  # Presence-based last-writer-wins for scalars; Map.merge for map-valued keys so a
  # sparse override keeps the other entries. Only keys PRESENT in `override` apply,
  # so a host-set `false` is honored (never collapses to a default).
  defp layer(base, override) do
    Enum.reduce(override, base, fn {key, value}, acc ->
      if key in @map_keys do
        Keyword.update(acc, key, value, &Map.merge(&1, value))
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

  @quality_value_keys [:quality, :autoquality_min_quality, :autoquality_max_quality]
  @quality_map_keys [
    :format_quality,
    :autoquality_format_min_quality,
    :autoquality_format_max_quality
  ]

  defp range_check!(resolved) do
    Enum.each(@quality_value_keys, &validate_quality_value!(&1, Keyword.fetch!(resolved, &1)))
    Enum.each(@quality_map_keys, &validate_quality_map!(&1, Keyword.fetch!(resolved, &1)))
    validate_target!(Keyword.fetch!(resolved, :autoquality_target))
    validate_allowed_error!(Keyword.fetch!(resolved, :autoquality_allowed_error))
    validate_brackets!(resolved)
    :ok
  end

  defp validate_quality_value!(key, value) do
    unless value in 1..100 do
      raise ArgumentError, "invalid config: #{key} (#{value}) must be between 1 and 100"
    end
  end

  defp validate_quality_map!(key, map) do
    Enum.each(map, fn {format, q} ->
      unless q in 1..100 do
        raise ArgumentError,
              "invalid config: #{key} #{inspect(format)} (#{q}) must be between 1 and 100"
      end
    end)
  end

  @perceptual_metrics [:ssimulacra2, :butteraugli]

  defp validate_target!(target_map) do
    Enum.each(target_map, fn {metric, value} ->
      validate_target_metric!(metric, value)
    end)
  end

  defp validate_target_metric!(:size, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError,
            "invalid config: autoquality_target :size (#{inspect(value)}) must be a positive integer"
    end
  end

  defp validate_target_metric!(metric, value) when metric in @perceptual_metrics do
    {lo, hi} = Metric.target_range(metric)

    unless is_number(value) and value >= lo and value <= hi do
      raise ArgumentError,
            "invalid config: autoquality_target #{inspect(metric)} (#{inspect(value)}) is out of range #{inspect({lo, hi})}"
    end
  end

  defp validate_target_metric!(metric, _value) do
    raise ArgumentError,
          "invalid config: autoquality_target has unknown metric #{inspect(metric)}"
  end

  defp validate_allowed_error!(error_map) do
    Enum.each(error_map, fn {metric, value} ->
      unless metric in @perceptual_metrics do
        raise ArgumentError,
              "invalid config: autoquality_allowed_error has unsupported metric #{inspect(metric)} (only :ssimulacra2/:butteraugli)"
      end

      unless is_number(value) and value >= 0 do
        raise ArgumentError,
              "invalid config: autoquality_allowed_error #{inspect(metric)} (#{inspect(value)}) must be a non-negative number"
      end
    end)
  end

  defp validate_brackets!(resolved) do
    base_min = Keyword.fetch!(resolved, :autoquality_min_quality)
    base_max = Keyword.fetch!(resolved, :autoquality_max_quality)
    format_min = Keyword.fetch!(resolved, :autoquality_format_min_quality)
    format_max = Keyword.fetch!(resolved, :autoquality_format_max_quality)

    if base_min > base_max do
      raise ArgumentError,
            "invalid config: autoquality_min_quality (#{base_min}) exceeds autoquality_max_quality (#{base_max})"
    end

    format_min
    |> Map.keys()
    |> Enum.concat(Map.keys(format_max))
    |> Enum.uniq()
    |> Enum.each(fn format ->
      effective_min = Map.get(format_min, format, base_min)
      effective_max = Map.get(format_max, format, base_max)

      if effective_min > effective_max do
        raise ArgumentError,
              "invalid config: effective autoquality bracket for #{inspect(format)} is inverted " <>
                "(min #{effective_min} > max #{effective_max})"
      end
    end)

    :ok
  end
end
