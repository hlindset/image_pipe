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

  use Boundary, top_level?: true, deps: [ImagePipe.Plan], exports: []

  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Output.QualitySearch
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
    jpeg_options: [type: {:struct, JpegOptions}],
    png_options: [type: {:struct, PngOptions}],
    webp_options: [type: {:struct, WebpOptions}],
    avif_options: [type: {:struct, AvifOptions}],
    jxl_options: [type: {:struct, JxlOptions}]
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
    autoquality_target: %{ssimulacra2: 78, butteraugli: 1.0},
    autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1},
    autoquality_format_min_quality: %{avif: 60, jpeg_xl: 45},
    autoquality_format_max_quality: %{avif: 65, jpeg_xl: 80},
    # Encoder options default to UNSET structs (all-nil): ImagePipe tracks libvips
    # defaults (emit nothing), never imgproxy's documented per-flag defaults.
    jpeg_options: %JpegOptions{},
    png_options: %PngOptions{},
    webp_options: %WebpOptions{},
    avif_options: %AvifOptions{},
    jxl_options: %JxlOptions{}
  ]

  @all_defaults @scalar_defaults ++ @map_defaults
  @map_keys Keyword.keys(@map_defaults)

  # Output `format()` ↔ neutral config key for the per-format encoder options.
  @encoder_option_config %{
    jpeg: :jpeg_options,
    png: :png_options,
    webp: :webp_options,
    avif: :avif_options,
    jpeg_xl: :jxl_options
  }

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

  @doc """
  Stamp resolved neutral config onto a base `Plan.Output`. Sets the encoder/
  metadata/color/autoquality fields; deliberately leaves `:quality` (the URL-level
  quality a dialect may have set) untouched, so a URL quality wins over the config
  `default_quality`/`format_qualities` base. Returns `{:error, _}` if the
  autoquality config is invalid (e.g. `:size` method with no target).
  """
  @spec apply_to_output(Output.t(), keyword()) :: {:ok, Output.t()} | {:error, term()}
  def apply_to_output(%Output{} = output, resolved) when is_list(resolved) do
    strip = Keyword.fetch!(resolved, :strip_metadata)
    keep = Keyword.fetch!(resolved, :keep_copyright)

    with {:ok, quality_search} <- QualitySearch.from_config(resolved) do
      {:ok,
       %{
         output
         | default_quality: {:quality, Keyword.fetch!(resolved, :quality)},
           format_qualities:
             normalize_format_qualities(Keyword.fetch!(resolved, :format_quality)),
           strip_metadata: strip,
           keep_copyright: strip and keep,
           color_profile: color_profile_policy(Keyword.fetch!(resolved, :strip_color_profile)),
           hdr: hdr_policy(Keyword.fetch!(resolved, :preserve_hdr)),
           encoder_options: encoder_options_from_config(resolved),
           quality_search: quality_search
       }}
    end
  end

  @doc """
  Build the `Plan.Output.encoder_options` map (`%{format => struct}`) from resolved
  neutral config, pruning all-`nil` structs so an unused feature yields `%{}`. Also
  used by the imgproxy parser to seed config defaults before overlaying URL tokens.
  """
  @spec encoder_options_from_config(keyword()) :: %{optional(atom()) => struct()}
  def encoder_options_from_config(resolved) do
    for {format, key} <- @encoder_option_config,
        struct = Keyword.fetch!(resolved, key),
        not struct.__struct__.all_nil?(struct),
        into: %{},
        do: {format, struct}
  end

  @doc """
  Reject host config keys a dialect declares unsupported. The adapter passes the
  neutral subset it honors (`:all` for full support); any key outside it raises a
  uniform, dialect-named `ArgumentError`. Otherwise returns the input keyword
  **verbatim** — it never filters, so a key is never silently dropped.
  """
  @spec reject_unsupported!(keyword(), [atom()] | :all, String.t()) :: keyword()
  def reject_unsupported!(neutral, :all, _dialect) when is_list(neutral), do: neutral

  def reject_unsupported!(neutral, supported, dialect)
      when is_list(neutral) and is_list(supported) and is_binary(dialect) do
    case Keyword.keys(neutral) -- supported do
      [] ->
        neutral

      unsupported ->
        raise ArgumentError,
              "the #{dialect} parser does not support config: #{inspect(unsupported)}"
    end
  end

  # Config carries bare per-format ints; Plan.Output wants the {:quality, n} shape.
  defp normalize_format_qualities(map), do: Map.new(map, fn {fmt, q} -> {fmt, {:quality, q}} end)

  defp color_profile_policy(true), do: :strip
  defp color_profile_policy(false), do: :preserve_source

  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map

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
        Keyword.update(acc, key, value, &merge_map_value(&1, value))
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

  # Encoder-option structs layer per-field via their own merge/2; the plain map
  # config keys (format_quality, autoquality_*) keep the Map.merge behavior.
  defp merge_map_value(%mod{} = base, %mod{} = over), do: mod.merge(base, over)
  defp merge_map_value(base, over) when is_map(base) and is_map(over), do: Map.merge(base, over)

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
    validate_encoder_options!(resolved)
    :ok
  end

  defp validate_encoder_options!(resolved) do
    j = Keyword.fetch!(resolved, :jpeg_options)
    enum!(:jpeg_options, :subsample_mode, j.subsample_mode, [:auto, :on, :off])
    int_range!(:jpeg_options, :quant_table, j.quant_table, 0..8)

    p = Keyword.fetch!(resolved, :png_options)
    enum!(:png_options, :bitdepth, p.bitdepth, [1, 2, 4, 8, 16])
    enum!(:png_options, :filter, p.filter, [:none, :sub, :up, :avg, :paeth, :all])

    w = Keyword.fetch!(resolved, :webp_options)
    enum!(:webp_options, :preset, w.preset, [:default, :photo, :picture, :drawing, :icon, :text])
    int_range!(:webp_options, :effort, w.effort, 0..6)

    a = Keyword.fetch!(resolved, :avif_options)
    enum!(:avif_options, :subsample_mode, a.subsample_mode, [:auto, :on, :off])
    int_range!(:avif_options, :effort, a.effort, 0..9)

    int_range!(:jxl_options, :effort, Keyword.fetch!(resolved, :jxl_options).effort, 1..9)
    :ok
  end

  defp int_range!(_key, _field, nil, _range), do: :ok

  defp int_range!(key, field, value, lo..hi//_) do
    unless is_integer(value) and value >= lo and value <= hi do
      raise ArgumentError,
            "invalid config: #{key} #{field} (#{inspect(value)}) must be in #{lo}..#{hi}"
    end
  end

  defp enum!(_key, _field, nil, _allowed), do: :ok

  defp enum!(key, field, value, allowed) do
    unless value in allowed do
      raise ArgumentError,
            "invalid config: #{key} #{field} (#{inspect(value)}) must be one of #{inspect(allowed)}"
    end
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
