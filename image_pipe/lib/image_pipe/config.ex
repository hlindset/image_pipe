defmodule ImagePipe.Config do
  @moduledoc """
  Reusable host configuration shared by the Plug and direct execution.

  Construct with `ImagePipe.config/1`. Configuration owns sources, caches,
  processing defaults, storage partitions, presets, request defaults, and URL
  settings (signing, source encryption, base URL). Inspection excludes its
  values.
  """
  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.API,
      ImagePipe.Cache,
      ImagePipe.Format,
      ImagePipe.Plan,
      ImagePipe.Security,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform,
      ImagePipe.URL
    ],
    exports: []

  alias ImagePipe.API.Presets
  alias ImagePipe.Cache
  alias ImagePipe.Format
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.Security
  alias ImagePipe.Source
  alias ImagePipe.Telemetry
  alias ImagePipe.Transform
  alias ImagePipe.URL.Config, as: URLConfig

  @enforce_keys [:options, :raw, :url]
  @derive {Inspect, except: [:options, :raw, :url]}
  defstruct @enforce_keys ++ [instance: nil]

  @type t :: %__MODULE__{
          options: keyword(),
          raw: keyword(),
          url: URLConfig.t(),
          instance: atom() | nil
        }

  @preset_keys [:presets, :request_defaults, :preset_lookup, :max_preset_lookups]

  # The URL options are validated by `ImagePipe.URL.Config`, which also owns
  # `:validate_against`; this configuration fills that in itself.
  @url_option_doc Keyword.delete(URLConfig.schema(), :validate_against)
  @url_keys Keyword.keys(@url_option_doc)

  @default_format_quality %{webp: 79, avif: 63}

  # A host's encoder settings win field by field over these.
  @default_encoder_options [
    jpeg_options: %JpegOptions{},
    png_options: %PngOptions{},
    webp_options: %WebpOptions{},
    avif_options: %AvifOptions{effort: 3, subsample_mode: :off}
  ]

  @processing_options [
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
      default: 10_000_000,
      doc: "Maximum size of an original, in bytes. A larger original fails the request."
    ],
    max_input_pixels: [
      type: :pos_integer,
      default: 40_000_000,
      doc: """
      Maximum pixels of a decoded original. For an animation, counts the \
      frames composited to reach the requested `page`. A larger original \
      fails the request.
      """
    ],
    max_input_frames: [
      type: :pos_integer,
      default: 1_000,
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
    max_intermediate_pixels: [
      type: :pos_integer,
      default: 100_000_000,
      doc: """
      Maximum pixels in a decoded frame buffered, downsampled, or delivered during \
      processing. Larger frames fail with `422`. Lazy intermediate frames \
      may be larger when a crop reduces them before those steps.
      """
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
      type: {:in, 1..100},
      type_doc: "`t:pos_integer/0`",
      default: 80,
      doc: "Encoder quality, `1..100`, for formats without a `:format_quality`."
    ],
    format_quality: [
      type: {:custom, __MODULE__, :validate_format_quality, []},
      type_doc: "map of `t:atom/0` to `t:pos_integer/0`",
      default: @default_format_quality,
      doc: """
      Quality per output format, `1..100`. Each format it sets replaces \
      that format's default. A request's `q` replaces this table, and its \
      `format-q` replaces the entries for the formats it lists. See \
      [`format-q`](processing/output.md#format-q).
      """
    ],
    strip_metadata: [
      type: :boolean,
      default: true,
      doc: "Remove EXIF, XMP, and other optional metadata from the output."
    ],
    keep_copyright: [
      type: :boolean,
      default: true,
      doc: "Keep copyright and artist fields when stripping metadata."
    ],
    stripped_dpi: [
      type: {:in, 1..65_535},
      type_doc: "`t:pos_integer/0`",
      default: 72,
      doc: """
      Density written to the output, `1..65535`, when metadata is stripped \
      and the request has no `dpi`.
      """
    ],
    strip_color_profile: [
      type: :boolean,
      default: true,
      doc: """
      Convert the output to sRGB (or gray) and leave out the original's ICC \
      profile. `false` keeps the original's profile.
      """
    ],
    preserve_hdr: [
      type: :boolean,
      default: false,
      doc: """
      Keep high bit depth in output formats that support it.
      """
    ],
    skip_processing_formats: [
      type: {:list, {:in, Format.source_formats()}},
      type_doc: "list of `t:atom/0`",
      default: [],
      doc: """
      Original formats, such as `[:gif]`, served unchanged instead of \
      processed when the request names no other `format` and draws no \
      watermark. The unchanged original keeps its metadata, including any \
      location data, and only `:max_body_bytes` limits it. See \
      [formats](processing/output.md#format).
      """
    ],
    autoquality: [
      type: :boolean,
      default: false,
      doc: """
      Picks each image's quality to meet `:autoquality_target` by \
      encoding and scoring several qualities. A request can turn it on or \
      off and set its own target with \
      [`autoquality`](processing/output.md#autoquality).
      """
    ],
    autoquality_target: [
      type: {:custom, __MODULE__, :validate_autoquality_target, []},
      type_doc: "`t:number/0`",
      default: 75,
      doc: """
      The SSIMULACRA2 score auto-quality aims for, above `0` and up to \
      `100`.
      """
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
      doc: "Default WebP encoder settings, as for `:jpeg_options`. `:effort` defaults to `4`."
    ],
    avif_options: [
      type: {:custom, __MODULE__, :validate_encoder_options, [AvifOptions]},
      type_doc: "`t:keyword/0`",
      doc:
        "Default AVIF encoder settings, as for `:jpeg_options`. `:effort` defaults to `3` and `:subsample_mode` to `:off`."
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
  ]

  @schema NimbleOptions.new!(
            @processing_options ++
              [
                cache: [
                  type: :keyword_list,
                  type_doc: "keyword list",
                  doc: """
                  Cache for processed images, stored on disk, such as \
                  `[root: "/var/cache/image_pipe/processed"]`. Takes the options of \
                  `ImagePipe.Cache.FileSystem`. See \
                  [caching processed images](caching-processed-images.md). Off by \
                  default.
                  """
                ],
                input_cache: [
                  type: :keyword_list,
                  type_doc: "keyword list",
                  doc: """
                  Cache for originals fetched from sources. Takes the same options as \
                  `:cache` except `:max_body_bytes`. \
                  See [originals cache](cache.md#originals-cache). Off by default.
                  """
                ],
                storage_inputs: [
                  type: {:list, {:custom, __MODULE__, :validate_storage_input, []}},
                  type_doc: "list of `{:header, name}` or `{:cookie, name}`",
                  default: [],
                  doc: """
                  Request headers and cookies whose values select separate cached \
                  copies, such as `[{:header, "x-tenant"}]`. They aren't sent to the \
                  source and don't change the image.
                  """
                ],
                watermarks: [
                  type:
                    {:map, {:custom, __MODULE__, :validate_watermark_name, []}, :keyword_list},
                  type_doc: "map of `t:atom/0` to `t:keyword/0`",
                  default: %{},
                  doc: """
                  Named watermark images that requests select with `wm=name`, as \
                  `%{logo: [source: "brand/logo.png", opacity: 0.6]}`. Names match \
                  `[a-z0-9_-]+`. `:source` is an image path that a configured source \
                  serves. `:opacity`, above `0` and at most `1`, defaults to `1` and \
                  multiplies the request's `wm-opacity`. See \
                  [watermarks](processing/watermark.md).
                  """
                ],
                request_watermarks: [
                  type: :boolean,
                  default: false,
                  doc: """
                  Let requests overlay any image the configured sources serve, with \
                  `wm-src64` or `wm-enc`, besides the named `:watermarks`.
                  """
                ],
                presets: [
                  type: :any,
                  type_doc: "map of `t:String.t/0` to fragment or `ImagePipe.URL` builder",
                  default: %{},
                  doc: """
                  Named sets of options that URLs select with `preset=name`, as URL \
                  fragments such as `%{"card" => "w=400/h=300/fit=cover"}` or \
                  `ImagePipe.URL` builders. See [defining presets](defining-presets.md).
                  """
                ],
                request_defaults: [
                  type: :any,
                  type_doc: "fragment or `ImagePipe.URL` builder",
                  doc: """
                  Options applied to the first group of every request, before presets \
                  and the request's own options. One group, with no `preset`.
                  """
                ],
                preset_lookup: [
                  type: {:custom, __MODULE__, :validate_preset_lookup, []},
                  type_doc: "`{module, keyword}`",
                  doc: """
                  Looks up preset names that `:presets` doesn't define, per request. \
                  See `ImagePipe.PresetLookup` and \
                  [storing presets in a database](storing-presets-in-a-database.md).
                  """
                ],
                max_preset_lookups: [
                  type: :pos_integer,
                  doc: """
                  Most distinct names one request may look up. Only with \
                  `:preset_lookup`. The default value is `32`.
                  """
                ]
              ]
          )

  @doc false
  # The option list for `ImagePipe.config/1`. The URL options are validated
  # before the schema, so they are documented here.
  def options_docs, do: NimbleOptions.docs(@url_option_doc ++ @schema.schema)

  @doc false
  @spec new!(keyword()) :: t()
  def new!(options) do
    known_options!(options)
    {url_options, remaining} = Keyword.split(options, @url_keys)
    url = URLConfig.new!(url_options)
    resolved = remaining |> Cache.validate_config!() |> Source.validate_config!()

    case NimbleOptions.validate(resolved, @schema) do
      {:ok, validated} ->
        {preset_options, validated} = Keyword.split(validated, @preset_keys)
        {presets, validate_against} = presets!(preset_options)

        validated =
          validated
          |> Keyword.put_new(:clock, &__MODULE__.system_time/0)
          |> Keyword.update!(:watermarks, &watermarks!(&1, validated))

        validate_against =
          Map.merge(validate_against, %{
            watermarks: Map.keys(Keyword.fetch!(validated, :watermarks)),
            request_watermarks: Keyword.fetch!(validated, :request_watermarks)
          })

        url = URLConfig.put_validate_against(url, validate_against)
        concealed_watermarks!(presets, url)

        resolved =
          validated
          |> processing!()
          |> Keyword.merge(url.options)
          |> Keyword.merge(presets)

        %__MODULE__{options: resolved, raw: options, url: url}

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{Exception.message(error)}"
    end
  end

  # The URL options are split off before the schema validates the rest, so the
  # schema's own unknown-option error would leave them out of the valid list.
  defp known_options!(options) do
    known = @url_keys ++ Keyword.keys(@schema.schema)

    case Keyword.keys(options) -- known do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "invalid ImagePipe configuration: unknown options #{inspect(Enum.uniq(unknown))}, " <>
                "valid options are: #{inspect(known)}"
    end
  end

  # Compiles static presets and request defaults; returns the resolved options
  # and the builder's view of them for `ImagePipe.url_config/2`.
  defp presets!(options) do
    presets =
      Map.new(Keyword.fetch!(options, :presets), fn {name, value} -> {name, plan(value)} end)

    case Presets.compile(presets, plan(options[:request_defaults])) do
      {:ok, compiled} ->
        lookup = lookup_options!(options)

        {[presets: compiled.presets, request_defaults: compiled.request_defaults] ++ lookup,
         Map.put(compiled, :lookup?, lookup != [])}

      {:error, message} ->
        raise ArgumentError, "invalid ImagePipe configuration: #{message}"
    end
  end

  # A static wm-enc can only be decrypted with source encryption keys, so a
  # configuration without them would answer every request using it with a 400.
  defp concealed_watermarks!(presets, url) do
    if not Security.source_encryption?(url.options) do
      defaults = Keyword.fetch!(presets, :request_defaults)

      [
        {"request_defaults", defaults}
        | Enum.map(presets[:presets], fn {name, preset} -> {~s(preset "#{name}"), preset} end)
      ]
      |> Enum.find(fn {_owner, preset} -> concealed_watermark?(preset) end)
      |> case do
        nil ->
          :ok

        {owner, _preset} ->
          raise ArgumentError,
                "invalid ImagePipe configuration: #{owner} uses wm-enc, which needs source_encryption_keys"
      end
    end
  end

  defp concealed_watermark?(%{groups: groups}),
    do: Enum.any?(groups, fn {_index, group} -> Map.has_key?(group, :watermark_token) end)

  defp concealed_watermark?(nil), do: false

  defp lookup_options!(options) do
    case {options[:preset_lookup], options[:max_preset_lookups]} do
      {nil, nil} ->
        []

      {nil, _max} ->
        raise ArgumentError,
              "invalid ImagePipe configuration: max_preset_lookups requires preset_lookup"

      {lookup, max} ->
        [preset_lookup: lookup, max_preset_lookups: max || 32]
    end
  end

  defp plan(%ImagePipe.URL{plan: plan}), do: {:plan, plan}
  defp plan(value), do: value

  @doc false
  def validate_preset_lookup({module, options}) when is_atom(module) and is_list(options) do
    with {:module, _module} <- Code.ensure_loaded(module),
         true <- function_exported?(module, :validate_options, 1),
         true <- function_exported?(module, :fetch, 2) do
      case module.validate_options(options) do
        {:ok, options} when is_list(options) ->
          {:ok, {module, options}}

        {:error, reason} ->
          {:error, "preset_lookup options are invalid: #{inspect(reason)}"}

        _invalid ->
          {:error,
           "#{inspect(module)}.validate_options/1 must return {:ok, keyword} or {:error, reason}"}
      end
    else
      _missing -> {:error, "#{inspect(module)} does not implement ImagePipe.PresetLookup"}
    end
  end

  def validate_preset_lookup(_lookup),
    do: {:error, "expected a {module, options} tuple implementing ImagePipe.PresetLookup"}

  @doc false
  # Only a supervised instance starts cache processes, so a configuration
  # used without one must not need them.
  @spec reject_unsupervised_processes!(t()) :: t()
  def reject_unsupervised_processes!(%__MODULE__{instance: nil} = config) do
    case Cache.child_specs(config.options) do
      [] ->
        config

      [_ | _] ->
        raise ArgumentError,
              "a bounded cache (one with max_size_bytes) " <>
                "must be used through an ImagePipe instance " <>
                "started with {ImagePipe, name: ..., ...}"
    end
  end

  def reject_unsupervised_processes!(%__MODULE__{} = config), do: config

  @doc false
  # Supervised instances store their configuration here, keyed by name, so
  # mounts can look it up per request.
  @spec publish(atom(), t(), %{atom() => t()}) :: :ok
  def publish(name, config, mounts),
    do: :persistent_term.put({__MODULE__, name}, {config, mounts})

  @doc false
  @spec unpublish(atom()) :: :ok
  def unpublish(name) do
    _erased? = :persistent_term.erase({__MODULE__, name})
    :ok
  end

  @doc false
  @spec fetch_instance!(atom(), atom() | nil) :: t()
  def fetch_instance!(name, mount) do
    case {:persistent_term.get({__MODULE__, name}, nil), mount} do
      {nil, _mount} ->
        raise ArgumentError, "ImagePipe instance #{inspect(name)} is not running"

      {{config, _mounts}, nil} ->
        config

      {{_config, mounts}, mount} ->
        case Map.fetch(mounts, mount) do
          {:ok, config} ->
            config

          :error ->
            raise ArgumentError,
                  "ImagePipe instance #{inspect(name)} has no mount named #{inspect(mount)}"
        end
    end
  end

  @doc false
  @spec override(t(), keyword()) :: t()
  def override(%__MODULE__{} = config, []), do: config

  # The result keeps the instance only while the instance runs every cache
  # process it needs.
  # URL options alone leave the caches and everything else as they are.
  def override(%__MODULE__{} = config, options) do
    case Keyword.keys(options) -- @url_keys do
      [] -> put_url_options(config, options)
      _other -> override_all(config, options)
    end
  end

  defp override_all(config, options) do
    overridden = new!(Keyword.merge(config.raw, options))
    running = Cache.child_specs(config.options)

    if config.instance != nil and
         Enum.all?(Cache.child_specs(overridden.options), &(&1 in running)),
       do: %{overridden | instance: config.instance},
       else: overridden
  end

  @doc false
  # The URL option names, which a named mount or an override can set.
  @spec url_keys() :: [atom()]
  def url_keys, do: @url_keys

  @doc false
  # The URL options' schema, which a named mount's options are validated with.
  @spec url_options_schema() :: keyword()
  def url_options_schema, do: @url_option_doc

  @doc false
  # Applies URL options on top of the configuration's own, for a named mount
  # or a URL-only override. Only the URL settings are rebuilt: the presets and
  # watermarks they're checked against stay the same, and so do the caches, so
  # the result keeps the instance.
  @spec put_url_options(t(), keyword()) :: t()
  def put_url_options(%__MODULE__{} = config, url_options) do
    url_options = config.raw |> Keyword.take(@url_keys) |> Keyword.merge(url_options)

    url =
      url_options
      |> URLConfig.new!()
      |> URLConfig.put_validate_against(Keyword.fetch!(config.url.options, :validate_against))

    concealed_watermarks!(config.options, url)

    %{
      config
      | options: Keyword.merge(config.options, url.options),
        raw: Keyword.merge(config.raw, url_options),
        url: url
    }
  end

  @watermark_schema NimbleOptions.new!(
                      source: [type: :string, required: true],
                      opacity: [type: {:custom, __MODULE__, :validate_opacity, []}, default: 1.0]
                    )

  @doc false
  # `unset` is the URL value that clears a watermark.
  def validate_watermark_name(:unset),
    do: {:error, "watermark name unset is reserved"}

  def validate_watermark_name(name) when is_atom(name) and not is_nil(name) do
    case Regex.match?(~r/\A[a-z0-9_-]+\z/, Atom.to_string(name)) do
      true -> {:ok, name}
      false -> {:error, "expected watermark names matching [a-z0-9_-]+, got: #{inspect(name)}"}
    end
  end

  def validate_watermark_name(name),
    do: {:error, "expected watermark names as atoms, got: #{inspect(name)}"}

  @doc false
  # The processing options with their defaults, which the server's
  # configuration reference documents.
  def processing_schema, do: @processing_options

  @doc false
  def system_time, do: System.os_time(:second)

  # The format qualities merge over the default table, and the encoder
  # settings over their defaults. The detector is resolved once here.
  defp processing!(options) do
    options =
      @default_encoder_options
      |> Enum.reduce(options, fn {key, default}, options ->
        Keyword.update(options, key, default, &default.__struct__.merge(default, &1))
      end)
      |> Keyword.update!(:format_quality, &Map.merge(@default_format_quality, &1))
      |> Keyword.update!(:detector, &Transform.resolve_detector/1)

    validate_detector_required!(options)
    options
  end

  # Requests check availability per class, so a detector that can run any of
  # its classes may be required.
  defp validate_detector_required!(options) do
    if Keyword.fetch!(options, :detector_required) and
         not detects_any_class?(Keyword.fetch!(options, :detector)) do
      raise ArgumentError,
            "invalid ImagePipe configuration: detector_required: " <>
              "the detector is not available in this build"
    end
  end

  defp detects_any_class?(nil), do: false

  defp detects_any_class?(detector),
    do: Enum.any?(detector.supported_classes([]), &detector.available?(classes: [&1]))

  @doc false
  def validate_format_quality(qualities) when is_map(qualities) do
    case Enum.reject(qualities, fn {format, quality} ->
           Format.output_format?(format) and quality in 1..100
         end) do
      [] -> {:ok, qualities}
      [{format, quality} | _rest] -> {:error, format_quality_error(format, quality)}
    end
  end

  def validate_format_quality(qualities),
    do: {:error, "expected a map of output format to quality, got: #{inspect(qualities)}"}

  defp format_quality_error(format, quality) do
    if Format.output_format?(format),
      do: "expected #{inspect(format)} quality in 1..100, got: #{inspect(quality)}",
      else: "unsupported format #{inspect(format)}"
  end

  @doc false
  def validate_autoquality_target(target) when is_number(target) and target > 0 and target <= 100,
    do: {:ok, target}

  def validate_autoquality_target(target),
    do: {:error, "expected a number above 0 and up to 100, got: #{inspect(target)}"}

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
  def validate_opacity(value) when is_number(value) and value > 0 and value <= 1,
    do: {:ok, value * 1.0}

  def validate_opacity(value),
    do: {:error, "expected a number greater than 0 and at most 1, got: #{inspect(value)}"}

  # Requests name assets by string; each entry's source must reach a mount.
  defp watermarks!(watermarks, options) do
    Map.new(watermarks, fn {name, entry} ->
      entry =
        case NimbleOptions.validate(entry, @watermark_schema) do
          {:ok, entry} -> entry
          {:error, error} -> raise_watermark!(name, Exception.message(error))
        end

      case Source.translate_configured(Keyword.fetch!(entry, :source), options) do
        {:ok, source} ->
          {Atom.to_string(name), %{source: source, opacity: Keyword.fetch!(entry, :opacity)}}

        {:error, _reason} ->
          raise_watermark!(name, "no configured source serves this path")
      end
    end)
  end

  defp raise_watermark!(name, message),
    do: raise(ArgumentError, "invalid ImagePipe configuration: watermark #{name}: #{message}")

  @doc false
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(_value),
    do: {:error, "expected {:header, name} or {:cookie, name} with a non-empty string name"}
end
