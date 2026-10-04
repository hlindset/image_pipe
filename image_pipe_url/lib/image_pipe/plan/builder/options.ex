defmodule ImagePipe.Plan.Builder.Options do
  @moduledoc false

  alias ImagePipe.Plan.Builder.OutputOptions
  alias ImagePipe.Plan.Builder.Values

  @anchors [
    :center,
    :top,
    :bottom,
    :left,
    :right,
    :top_left,
    :top_right,
    :bottom_left,
    :bottom_right
  ]
  @axes [:horizontal, :vertical, :both]

  @docs "https://hexdocs.pm/image_pipe"

  def request!(options), do: validate_unsettable!(options, request_schema())

  def request_schema do
    [
      orient: [
        type: {:in, [:auto, :none]},
        type_doc: "`:auto` or `:none`",
        doc: """
        `:auto` applies the original's EXIF orientation, and `:none` ignores
        it. The URL option is [`orient`](#{@docs}/crop.html#orient).
        """
      ],
      page: [
        type: :non_neg_integer,
        doc: """
        The zero-based page or frame of the original to use. The URL option is
        [`page`](#{@docs}/request.html#page).
        """
      ],
      filename: [
        type: custom(:path_token),
        type_doc: "`t:String.t/0`",
        doc: """
        The file name without extension, of ASCII letters, digits, `.`, `_`,
        and `-`. The response's extension is appended. The URL option is
        [`filename`](#{@docs}/request.html#filename).
        """
      ],
      attachment: [
        type: :boolean,
        doc: """
        Makes browsers download the response. The URL option is
        [`attachment`](#{@docs}/request.html#attachment).
        """
      ],
      cachebuster: [
        type: custom(:path_token),
        type_doc: "`t:String.t/0`",
        doc: """
        A token that makes the server store a copy separate from the one for
        the same URL without it: ASCII letters, digits, `.`, `_`, and `-`. The URL option is
        [`cb`](#{@docs}/request.html#cb).
        """
      ],
      expires: [
        type: :pos_integer,
        doc: """
        A Unix time in seconds. The URL stops working after that second. The URL option
        is [`expires`](#{@docs}/request.html#expires).
        """
      ],
      debug: [
        type: :boolean,
        doc: """
        Adds debug response headers when the server allows them with
        `allow_debug_headers`. The URL option is [`debug`](#{@docs}/request.html#debug).
        """
      ]
    ]
  end

  def group!(options) do
    {resize, group} =
      options
      |> validate_unsettable!(group_schema(), Keyword.keys(transform_schema()))
      |> Map.pop(:resize, [])

    group = if Map.get(group, :presets) == [], do: Map.delete(group, :presets), else: group

    case Map.merge(group, validate_unsettable!(resize, resize_schema())) do
      values when map_size(values) > 0 -> values
      _empty -> raise ArgumentError, "a group must contain at least one option"
    end
  end

  def output!(options), do: validate_unsettable!(options, OutputOptions.schema())

  # Every option accepts `:unset`, which clears it from presets and request
  # defaults. Unset options skip validation, so an error lists only the
  # values the option really takes.
  defp validate_unsettable!(options, schema, unsettable \\ nil) do
    unsettable = unsettable || Keyword.keys(schema)

    with :ok <- unique_keywords(options),
         {unset, set} = Enum.split_with(options, &unset?(&1, unsettable)),
         {:ok, values} <- validate(set, schema) do
      Map.merge(Map.new(values), Map.new(unset))
    else
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp unset?({key, value}, unsettable), do: value == :unset and key in unsettable

  defp group_schema do
    [
      presets: [type: {:list, {:custom, Values, :cast, [:preset_name]}}],
      resize: [type: :keyword_list]
    ] ++ transform_schema()
  end

  defp transform_schema do
    [
      rotate: [type: custom(:rotate)],
      flip: [type: {:in, @axes}],
      gray: [type: :boolean],
      bitonal: [type: :boolean],
      dpr: [type: custom(:positive)],
      trim: [type: custom(:trim)],
      trim_symmetry: [type: {:in, @axes}],
      crop: [type: custom(:crop)],
      region: [type: custom(:region)],
      crop_ratio: [type: custom(:ratio)],
      crop_ratio_enlarge: [type: :boolean],
      anchor: [type: {:in, @anchors ++ [:smart, :smart_face]}],
      focus: [type: custom(:focus)],
      detect: [type: custom(:detect)],
      anchor_offset: [type: custom(:offset)],
      extend: [type: :boolean],
      extend_ratio: [type: :boolean],
      extend_at: [type: {:in, @anchors}],
      extend_offset: [type: custom(:offset)],
      blur: [type: custom(:nonnegative)],
      progressive_blur: [type: custom(:progressive_blur)],
      sharpen: [type: custom(:nonnegative)],
      pixelate: [type: :pos_integer],
      brightness: [type: {:in, -255..255}],
      contrast: [type: custom(:positive)],
      saturation: [type: custom(:positive)],
      monochrome: [type: custom(:monochrome)],
      duotone: [type: custom(:duotone)],
      colorize: [type: custom(:colorize)],
      gradient: [type: custom(:gradient)],
      padding: [type: custom(:padding)],
      background: [type: custom(:background)],
      watermark: [type: custom(:watermark_name)],
      watermark_source: [type: custom(:source)],
      watermark_opacity: [type: custom(:fraction)],
      watermark_scale: [type: custom(:scale)],
      watermark_at: [type: {:in, @anchors}],
      watermark_offset: [type: custom(:offset)],
      watermark_tile: [type: :boolean],
      watermark_gap: [type: custom(:gap)]
    ]
  end

  defp resize_schema do
    [
      width: [type: {:or, [:pos_integer, {:in, [:auto]}]}],
      height: [type: {:or, [:pos_integer, {:in, [:auto]}]}],
      min_width: [type: :pos_integer],
      min_height: [type: :pos_integer],
      fit: [type: {:in, [:contain, :cover, :stretch, :auto]}],
      enlarge: [type: :boolean],
      zoom: [type: custom(:zoom)]
    ]
  end

  defp custom(kind), do: {:custom, Values, :cast, [kind]}

  # NimbleOptions accepts repeated keywords; a plan's explicit options must
  # have an unambiguous value at every nesting level.
  def validate(options, schema) do
    with :ok <- unique_keywords(options),
         {:ok, values} <- NimbleOptions.validate(options, schema) do
      {:ok, values}
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, _message} = error -> error
    end
  end

  defp unique_keywords(options) when is_list(options) do
    case Keyword.keyword?(options) do
      true -> unique_entries(options)
      false -> {:error, "expected a keyword list"}
    end
  end

  defp unique_keywords(_options), do: {:error, "expected a keyword list"}

  defp unique_entries(options) do
    keys = Keyword.keys(options)

    case Enum.uniq(keys) == keys do
      true -> validate_nested_keywords(options)
      false -> {:error, "duplicate option keys are not allowed"}
    end
  end

  defp validate_nested_keywords(options) do
    Enum.reduce_while(options, :ok, fn {_key, value}, :ok ->
      case nested_keywords(value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp nested_keywords(value) when is_list(value) do
    case Keyword.keyword?(value) do
      true -> unique_entries(value)
      false -> :ok
    end
  end

  defp nested_keywords(_value), do: :ok
end
