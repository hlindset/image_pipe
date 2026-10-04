defmodule ImagePipe.Processing.Config do
  @moduledoc false
  alias ImagePipe.Format
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Output.QualitySearch.Metric
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform

  @default_max_body_bytes 10_000_000
  @default_max_input_pixels 40_000_000
  @default_max_input_frames 1_000

  @scalar_defaults [
    strip_metadata: true,
    keep_copyright: true,
    stripped_dpi: 72,
    strip_color_profile: true,
    preserve_hdr: false,
    skip_processing_formats: [],
    quality: 80,
    autoquality_method: :none,
    autoquality_min_quality: 70,
    autoquality_max_quality: 80,
    autoquality_max_resolution: 0,
    autoquality_max_iterations: 6
  ]

  @map_defaults [
    format_quality: %{webp: 79, avif: 63},
    autoquality_target: %{ssimulacra2: 78, butteraugli: 1.0},
    autoquality_allowed_error: %{ssimulacra2: 1.0, butteraugli: 0.1},
    autoquality_format_min_quality: %{avif: 60},
    autoquality_format_max_quality: %{avif: 65},
    jpeg_options: %JpegOptions{},
    png_options: %PngOptions{},
    webp_options: %WebpOptions{},
    avif_options: %AvifOptions{effort: 3}
  ]

  @map_keys Keyword.keys(@map_defaults)

  @options_schema NimbleOptions.new!(
                    sources: [
                      type: :any,
                      type_doc: "`t:keyword/0`",
                      doc: """
                      Named sources that originals are read from, as \
                      `name: [adapter: module, match: rule, options: [...]]`. See \
                      [sources](sources.md#routing-image-paths-to-sources).
                      """
                    ],
                    source_cache_policy: [
                      type: :keyword_list,
                      doc: """
                      Default cache storage and freshness policy for every source. See \
                      `ImagePipe.Source.CachePolicy` and \
                      [source cache settings](cache.md#source-cache-settings).
                      """
                    ],
                    max_body_bytes: [
                      type: :pos_integer,
                      default: @default_max_body_bytes,
                      doc:
                        "Maximum size of an original, in bytes. A larger original fails the request."
                    ],
                    max_input_pixels: [
                      type: :pos_integer,
                      default: @default_max_input_pixels,
                      doc: """
                      Maximum pixels of a decoded original. For an animation, counts the \
                      frames composited to reach the requested `page`. A larger original \
                      fails the request.
                      """
                    ],
                    max_input_frames: [
                      type: :pos_integer,
                      default: @default_max_input_frames,
                      doc: """
                      Maximum frames or pages an original may declare. An original with \
                      more fails the request.
                      """
                    ],
                    max_result_width: [
                      type: :pos_integer,
                      default: 8_192,
                      doc: "Maximum output width. Larger results are scaled down to fit."
                    ],
                    max_result_height: [
                      type: :pos_integer,
                      default: 8_192,
                      doc: "Maximum output height. Larger results are scaled down to fit."
                    ],
                    max_result_pixels: [
                      type: :pos_integer,
                      default: 40_000_000,
                      doc: "Maximum output pixels. Larger results are scaled down to fit."
                    ],
                    processing_pool: [
                      type: {:or, [:atom, :pid]},
                      type_doc: "`t:atom/0` or `t:pid/0`",
                      doc: """
                      A running `ImagePipe.ProcessingPool`, by name or PID, that limits how \
                      many images are processed at once. See \
                      [limiting concurrent processing](processing-controls.md).
                      """
                    ],
                    auto_avif: [
                      type: :boolean,
                      default: true,
                      doc: "Serve AVIF when the request's `Accept` header lists it."
                    ],
                    auto_webp: [
                      type: :boolean,
                      default: true,
                      doc: "Serve WebP when the request's `Accept` header lists it."
                    ],
                    format_order: [
                      type: {:custom, __MODULE__, :validate_format_order, []},
                      type_doc: "list of `:avif` and `:webp`",
                      doc: """
                      Which format wins when `Accept` lists both. A format left out of the \
                      list comes after the listed ones. The default value is \
                      `[:avif, :webp]`.
                      """
                    ],
                    quality: [
                      type: :pos_integer,
                      doc:
                        "Encoder quality, `1..100`, for formats without a `:format_quality`. The default value is `80`."
                    ],
                    format_quality: [
                      type: {:map, :atom, :pos_integer},
                      doc: """
                      Quality per output format, `1..100`. Merged with the defaults, \
                      `%{webp: 79, avif: 63}`. A request's `q` wins over both.
                      """
                    ],
                    strip_metadata: [
                      type: :boolean,
                      doc:
                        "Remove EXIF, XMP, and other optional metadata from the output. The default value is `true`."
                    ],
                    keep_copyright: [
                      type: :boolean,
                      doc:
                        "Keep copyright and artist fields when stripping metadata. The default value is `true`."
                    ],
                    stripped_dpi: [
                      type: {:in, 1..65_535},
                      type_doc: "`t:pos_integer/0`",
                      doc: """
                      Density written to the output, `1..65535`, when metadata is stripped \
                      and the request has no `dpi`. The default value is `72`.
                      """
                    ],
                    strip_color_profile: [
                      type: :boolean,
                      doc: """
                      Convert the output to sRGB (or gray) and leave out the original's ICC \
                      profile. `false` keeps the original's profile. The default value is `true`.
                      """
                    ],
                    preserve_hdr: [
                      type: :boolean,
                      doc: """
                      Keep high bit depth in output formats that support it. The default \
                      value is `false`.
                      """
                    ],
                    skip_processing_formats: [
                      type: {:list, {:in, Format.source_formats()}},
                      type_doc: "list of `t:atom/0`",
                      doc: """
                      Original formats, such as `[:gif]`, served unchanged instead of \
                      processed when the request names no other `format` and draws no \
                      watermark. The unchanged original keeps its metadata, including any \
                      location data, and only `:max_body_bytes` limits it. See \
                      [formats](processing/output.md#format). The default value \
                      is `[]`.
                      """
                    ],
                    autoquality_method: [
                      type: {:in, [:none, :size, :ssimulacra2, :butteraugli]},
                      doc: """
                      Searches for a quality between the minimum and maximum quality: the \
                      lowest that meets a `:ssimulacra2` or `:butteraugli` target, or the \
                      highest whose output fits a `:size` byte target. `:none` turns search \
                      off. Search encodes several candidates. The default value is `:none`.
                      """
                    ],
                    autoquality_target: [
                      type: {:map, :atom, {:or, [:integer, :float]}},
                      type_doc: "`t:map/0`",
                      doc: """
                      Target per method. Merged with the defaults, \
                      `%{ssimulacra2: 78, butteraugli: 1.0}`. SSIMULACRA2 targets are \
                      `0..100` and Butteraugli targets `0..25`. `autoquality_method: :size` \
                      needs a target in whole bytes, such as `%{size: 50_000}`, or the \
                      configuration is rejected.
                      """
                    ],
                    autoquality_allowed_error: [
                      type: {:map, :atom, {:or, [:integer, :float]}},
                      type_doc: "`t:map/0`",
                      doc: """
                      How far from the target a result may land, per method. Merged with \
                      the defaults, `%{ssimulacra2: 1.0, butteraugli: 0.1}`.
                      """
                    ],
                    autoquality_min_quality: [
                      type: :pos_integer,
                      doc: "Lowest quality the search tries, `1..100`. The default value is `70`."
                    ],
                    autoquality_max_quality: [
                      type: :pos_integer,
                      doc:
                        "Highest quality the search tries, `1..100`. The default value is `80`."
                    ],
                    autoquality_format_min_quality: [
                      type: {:map, :atom, :pos_integer},
                      doc: """
                      Lowest quality per format, overriding `:autoquality_min_quality`. \
                      Merged with the defaults, `%{avif: 60}`.
                      """
                    ],
                    autoquality_format_max_quality: [
                      type: {:map, :atom, :pos_integer},
                      doc: """
                      Highest quality per format, overriding `:autoquality_max_quality`. \
                      Merged with the defaults, `%{avif: 65}`.
                      """
                    ],
                    autoquality_max_resolution: [
                      type: :non_neg_integer,
                      doc: """
                      Results larger than this many megapixels skip the search and use \
                      the normal quality. `0`, the default, searches at every size.
                      """
                    ],
                    autoquality_max_iterations: [
                      type: :pos_integer,
                      doc: "Most candidates one search encodes. The default value is `6`."
                    ],
                    jpeg_options: [
                      type: {:custom, __MODULE__, :validate_encoder_options, [JpegOptions]},
                      type_doc: "`t:keyword/0`",
                      doc: """
                      Default JPEG encoder settings, as a keyword list with the fields \
                      of the `jpeg_options:` option of `ImagePipe.URL.output/2`, such as \
                      `[interlace: true]`. A request's settings win field by field. See \
                      [encoder options](processing/output.md#encoder-options) and the \
                      builder names in \
                      [URL option names](`ImagePipe.URL#module-url-option-names`).
                      """
                    ],
                    png_options: [
                      type: {:custom, __MODULE__, :validate_encoder_options, [PngOptions]},
                      type_doc: "`t:keyword/0`",
                      doc: "Default PNG encoder settings, as for `:jpeg_options`."
                    ],
                    webp_options: [
                      type: {:custom, __MODULE__, :validate_encoder_options, [WebpOptions]},
                      type_doc: "`t:keyword/0`",
                      doc:
                        "Default WebP encoder settings, as for `:jpeg_options`. `:effort` defaults to `4`."
                    ],
                    avif_options: [
                      type: {:custom, __MODULE__, :validate_encoder_options, [AvifOptions]},
                      type_doc: "`t:keyword/0`",
                      doc:
                        "Default AVIF encoder settings, as for `:jpeg_options`. `:effort` defaults to `3`."
                    ],
                    detector: [
                      type: {:or, [{:in, [:default, nil]}, :atom]},
                      type_doc: "`:default`, `nil`, or `t:module/0`",
                      default: :default,
                      doc: """
                      The detector for face and object detection. `:default` uses the \
                      built-in detector when its dependencies are installed, `nil` turns \
                      detection off, and a module uses a custom detector. See \
                      [enabling detection](enabling-detection.md).
                      """
                    ],
                    detector_required: [
                      type: :boolean,
                      default: false,
                      doc: """
                      Fail requests that ask for detection when it can't run: `501` when \
                      the detector can't detect the requested classes in this build, `503` \
                      when its models aren't downloaded, and `500` when detection fails. \
                      With `false`, the crop falls back to attention cropping. \
                      `anchor=smart-face` always falls back. With `true`, `ImagePipe.config/1` \
                      raises `ArgumentError` when the detector can't detect any class.
                      """
                    ],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      type_doc: "list of `t:atom/0`",
                      default: Telemetry.default_prefix(),
                      doc: "Prefix of every telemetry event name. See [telemetry](telemetry.md)."
                    ],
                    clock: [
                      type: {:custom, __MODULE__, :validate_clock, []},
                      type_doc: "`(-> integer())`",
                      doc: """
                      Returns the current Unix time in seconds, for checking a URL's \
                      `expires`. The system clock by default.
                      """
                    ]
                  )

  @doc false
  def schema, do: @options_schema.schema

  def system_time, do: System.os_time(:second)

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
  def validate_encoder_options(options, module) when is_list(options) do
    case NimbleOptions.validate(options, module.schema()) do
      {:ok, options} -> {:ok, struct!(module, options)}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  def validate_encoder_options(_options, _module), do: {:error, "expected a keyword list"}

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
    validate_size_target!(resolved)
    validate_allowed_error!(Keyword.fetch!(resolved, :autoquality_allowed_error))
    validate_brackets!(resolved)
    validate_detector_required!(resolved)
    :ok
  end

  # Requests check availability per class, so a detector that can run any of
  # its classes may be required.
  defp validate_detector_required!(resolved) do
    detector = Keyword.get(resolved, :detector, :default)

    if Keyword.get(resolved, :detector_required, false) and not detects_any_class?(detector) do
      raise ArgumentError,
            "invalid ImagePipe processing options: detector_required: " <>
              "the detector is not available in this build"
    end
  end

  defp detects_any_class?(detector) do
    case Transform.resolve_detector(detector) do
      nil ->
        false

      module ->
        Enum.any?(module.supported_classes([]), &module.available?(classes: [&1]))
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

  defp validate_size_target!(resolved) do
    if Keyword.fetch!(resolved, :autoquality_method) == :size and
         not Map.has_key?(Keyword.fetch!(resolved, :autoquality_target), :size) do
      raise ArgumentError,
            "invalid ImagePipe processing options: autoquality_method :size needs a :size " <>
              "entry in autoquality_target, such as %{size: 50_000}"
    end
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
