defmodule ImagePipe.Processing.Config do
  @moduledoc false
  alias ImagePipe.Format
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Output.QualitySearch.Metric
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @default_max_body_bytes 10_000_000
  @default_max_input_pixels 40_000_000

  @scalar_defaults [
    strip_metadata: true,
    keep_copyright: true,
    strip_color_profile: true,
    preserve_hdr: false,
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
    jpeg_options: %JpegOptions{},
    png_options: %PngOptions{},
    webp_options: %WebpOptions{},
    avif_options: %AvifOptions{},
    jxl_options: %JxlOptions{}
  ]

  @map_keys Keyword.keys(@map_defaults)

  @options_schema NimbleOptions.new!(
                    sources: [type: :map],
                    source_cache_policy: [type: :keyword_list],
                    processing_pool: [type: {:or, [:atom, :pid]}],
                    max_body_bytes: [type: :pos_integer, default: @default_max_body_bytes],
                    max_input_pixels: [type: :pos_integer, default: @default_max_input_pixels],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      default: Telemetry.default_prefix()
                    ],
                    auto_avif: [type: :boolean, default: true],
                    auto_webp: [type: :boolean, default: true],
                    auto_jpeg_xl: [type: :boolean, default: true],
                    format_order: [
                      type: {:custom, __MODULE__, :validate_format_order, []}
                    ],
                    output_capabilities: [type: {:map, :atom, :boolean}],
                    max_result_width: [type: :pos_integer, default: 8_192],
                    max_result_height: [type: :pos_integer, default: 8_192],
                    max_result_pixels: [type: :pos_integer, default: 40_000_000],
                    strip_metadata: [type: :boolean],
                    keep_copyright: [type: :boolean],
                    quality: [type: :pos_integer],
                    format_quality: [type: {:map, :atom, :pos_integer}],
                    strip_color_profile: [type: :boolean],
                    preserve_hdr: [type: :boolean],
                    autoquality_method: [type: {:in, [:none, :size, :ssimulacra2, :butteraugli]}],
                    autoquality_target: [type: {:map, :atom, {:or, [:integer, :float]}}],
                    autoquality_min_quality: [type: :pos_integer],
                    autoquality_max_quality: [type: :pos_integer],
                    autoquality_allowed_error: [
                      type: {:map, :atom, {:or, [:integer, :float]}}
                    ],
                    autoquality_format_min_quality: [type: {:map, :atom, :pos_integer}],
                    autoquality_format_max_quality: [type: {:map, :atom, :pos_integer}],
                    autoquality_max_resolution: [type: :non_neg_integer],
                    autoquality_max_iterations: [type: :pos_integer],
                    jpeg_options: [type: {:struct, JpegOptions}],
                    png_options: [type: {:struct, PngOptions}],
                    webp_options: [type: {:struct, WebpOptions}],
                    avif_options: [type: {:struct, AvifOptions}],
                    jxl_options: [type: {:struct, JxlOptions}],
                    clock: [
                      type: {:custom, __MODULE__, :validate_clock, []}
                    ],
                    source_schemes: [
                      type: {:custom, __MODULE__, :validate_source_schemes, []},
                      default: %{}
                    ],
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      default: :default
                    ],
                    detector_required: [
                      type: :boolean,
                      default: false
                    ]
                  )

  def schema, do: @options_schema.schema

  def validate!(opts) do
    opts |> Source.validate_config!() |> validate_known_opts!() |> resolve!()
  end

  @doc false
  def validate_clock(clock) when is_function(clock, 0), do: {:ok, clock}

  def validate_clock(_clock), do: {:error, "expected a zero-arity function"}

  @doc false
  def validate_telemetry_prefix([_ | _] = prefix) do
    if Enum.all?(prefix, &is_atom/1),
      do: {:ok, prefix},
      else: {:error, "expected a non-empty list of atoms"}
  end

  def validate_telemetry_prefix(_prefix), do: {:error, "expected a non-empty list of atoms"}

  @doc false
  def validate_format_order(order) do
    modern_formats = Format.modern_formats()

    with true <- is_list(order),
         true <- order != [],
         true <- Enum.all?(order, &(&1 in modern_formats)),
         true <- length(Enum.uniq(order)) == length(order) do
      {:ok, order}
    else
      false -> format_order_error(order, modern_formats)
    end
  end

  defp format_order_error(order, _modern_formats) when not is_list(order),
    do: {:error, "expected a list of modern format atoms"}

  defp format_order_error([], _modern_formats),
    do: {:error, "expected a non-empty list of modern formats"}

  defp format_order_error(order, modern_formats) do
    if Enum.all?(order, &(&1 in modern_formats)) do
      {:error, "expected distinct formats, got: #{inspect(order)}"}
    else
      {:error, "expected formats from #{inspect(modern_formats)}, got: #{inspect(order)}"}
    end
  end

  @doc false
  def validate_source_schemes(%{} = schemes) do
    if Enum.all?(schemes, &valid_source_scheme_entry?/1) do
      {:ok, schemes}
    else
      {:error, "expected a map from canonical custom scheme names to {module, keyword_options}"}
    end
  end

  def validate_source_schemes(_schemes) do
    {:error, "expected a map from canonical custom scheme names to {module, keyword_options}"}
  end

  defp valid_source_scheme_entry?({scheme, {translator, translator_opts}}) do
    valid_custom_scheme?(scheme) and valid_source_scheme_translator?(translator) and
      Keyword.keyword?(translator_opts)
  end

  defp valid_source_scheme_entry?(_entry), do: false

  defp valid_custom_scheme?(scheme) when is_binary(scheme) do
    scheme not in ["http", "https", "s3"] and
      String.match?(scheme, ~r/^[a-z][a-z0-9+.\-]*$/)
  end

  defp valid_custom_scheme?(_scheme), do: false

  defp valid_source_scheme_translator?(translator) when is_atom(translator) do
    Code.ensure_loaded?(translator) and function_exported?(translator, :translate, 2)
  end

  defp valid_source_scheme_translator?(_translator), do: false

  defp validate_known_opts!(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.put_new(validated_opts, :clock, fn -> System.os_time(:second) end)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe processing options: #{Exception.message(error)}"
    end
  end

  @doc false
  def resolve!(opts) do
    resolved = layer(@scalar_defaults ++ @map_defaults, opts)
    range_check!(resolved)
    resolved
  end

  defp layer(base, override) do
    Enum.reduce(override, base, fn {key, value}, acc ->
      if key in @map_keys do
        Keyword.update(acc, key, value, &merge_map_value(&1, value))
      else
        Keyword.put(acc, key, value)
      end
    end)
  end

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
    jpeg = Keyword.fetch!(resolved, :jpeg_options)
    enum!(:jpeg_options, :subsample_mode, jpeg.subsample_mode, [:auto, :on, :off])
    int_range!(:jpeg_options, :quant_table, jpeg.quant_table, 0..8)

    bools!(:jpeg_options, jpeg, [
      :interlace,
      :trellis_quant,
      :overshoot_deringing,
      :optimize_scans
    ])

    png = Keyword.fetch!(resolved, :png_options)
    enum!(:png_options, :bitdepth, png.bitdepth, [1, 2, 4, 8, 16])
    enum!(:png_options, :filter, png.filter, [:none, :sub, :up, :avg, :paeth, :all])
    bools!(:png_options, png, [:interlace, :palette])

    webp = Keyword.fetch!(resolved, :webp_options)

    enum!(:webp_options, :preset, webp.preset, [
      :default,
      :photo,
      :picture,
      :drawing,
      :icon,
      :text
    ])

    int_range!(:webp_options, :effort, webp.effort, 0..6)
    bools!(:webp_options, webp, [:lossless, :near_lossless, :smart_subsample])

    avif = Keyword.fetch!(resolved, :avif_options)
    enum!(:avif_options, :subsample_mode, avif.subsample_mode, [:auto, :on, :off])
    int_range!(:avif_options, :effort, avif.effort, 0..9)

    int_range!(:jxl_options, :effort, Keyword.fetch!(resolved, :jxl_options).effort, 1..9)
    :ok
  end

  defp bools!(key, struct, fields),
    do: Enum.each(fields, &bool!(key, &1, Map.fetch!(struct, &1)))

  defp bool!(_key, _field, nil), do: :ok
  defp bool!(_key, _field, value) when is_boolean(value), do: :ok

  defp bool!(key, field, value) do
    raise ArgumentError,
          "invalid ImagePipe processing options: #{key} #{field} (#{inspect(value)}) must be a boolean"
  end

  defp int_range!(_key, _field, nil, _range), do: :ok

  defp int_range!(key, field, value, lo..hi//_) do
    unless is_integer(value) and value >= lo and value <= hi do
      raise ArgumentError,
            "invalid ImagePipe processing options: #{key} #{field} (#{inspect(value)}) must be in #{lo}..#{hi}"
    end
  end

  defp enum!(_key, _field, nil, _allowed), do: :ok

  defp enum!(key, field, value, allowed) do
    unless value in allowed do
      raise ArgumentError,
            "invalid ImagePipe processing options: #{key} #{field} (#{inspect(value)}) must be one of #{inspect(allowed)}"
    end
  end

  defp validate_quality_value!(key, value) do
    unless value in 1..100 do
      raise ArgumentError,
            "invalid ImagePipe processing options: #{key} (#{value}) must be between 1 and 100"
    end
  end

  defp validate_quality_map!(key, map) do
    Enum.each(map, fn {format, quality} ->
      unless Format.output_format?(format) do
        raise ArgumentError,
              "invalid ImagePipe processing options: #{key} has unsupported format #{inspect(format)}"
      end

      unless quality in 1..100 do
        raise ArgumentError,
              "invalid ImagePipe processing options: #{key} #{inspect(format)} (#{quality}) must be between 1 and 100"
      end
    end)
  end

  @perceptual_metrics [:ssimulacra2, :butteraugli]

  defp validate_target!(target_map) do
    Enum.each(target_map, fn {metric, value} -> validate_target_metric!(metric, value) end)
  end

  defp validate_target_metric!(:size, value) do
    unless is_integer(value) and value > 0 do
      raise ArgumentError,
            "invalid ImagePipe processing options: autoquality_target :size (#{inspect(value)}) must be a positive integer"
    end
  end

  defp validate_target_metric!(metric, value) when metric in @perceptual_metrics do
    {low, high} = Metric.target_range(metric)

    unless is_number(value) and value >= low and value <= high do
      raise ArgumentError,
            "invalid ImagePipe processing options: autoquality_target #{inspect(metric)} (#{inspect(value)}) is out of range #{inspect({low, high})}"
    end
  end

  defp validate_target_metric!(metric, _value) do
    raise ArgumentError,
          "invalid ImagePipe processing options: autoquality_target has unknown metric #{inspect(metric)}"
  end

  defp validate_allowed_error!(error_map) do
    Enum.each(error_map, fn {metric, value} ->
      unless metric in @perceptual_metrics do
        raise ArgumentError,
              "invalid ImagePipe processing options: autoquality_allowed_error has unsupported metric #{inspect(metric)}"
      end

      unless is_number(value) and value >= 0 do
        raise ArgumentError,
              "invalid ImagePipe processing options: autoquality_allowed_error #{inspect(metric)} (#{inspect(value)}) must be a non-negative number"
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
            "invalid ImagePipe processing options: autoquality_min_quality (#{base_min}) exceeds autoquality_max_quality (#{base_max})"
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
              "invalid ImagePipe processing options: effective autoquality bracket for #{inspect(format)} is inverted " <>
                "(min #{effective_min} > max #{effective_max})"
      end
    end)

    :ok
  end
end
