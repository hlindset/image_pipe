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

  def request!(options) do
    validate!(options,
      orient: [type: {:in, [:auto, :none]}],
      filename: [type: custom(:path_token)],
      attachment: [type: :boolean],
      cachebuster: [type: custom(:path_token)],
      expires: [type: :pos_integer],
      debug: [type: :boolean]
    )
  end

  def group!(options) do
    {resize, group} = options |> validate!(group_schema()) |> Map.pop(:resize, [])

    case Map.merge(group, Map.new(resize)) do
      values when map_size(values) > 0 -> values
      _empty -> raise ArgumentError, "a group must contain at least one option"
    end
  end

  def output!(options), do: validate!(options, OutputOptions.schema())

  defp group_schema do
    [
      resize: [type: :keyword_list, keys: resize_schema()],
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
      background: [type: custom(:background)]
    ]
  end

  defp resize_schema do
    [
      width: [type: {:or, [:pos_integer, {:in, [:auto]}]}],
      height: [type: {:or, [:pos_integer, {:in, [:auto]}]}],
      min_width: [type: :pos_integer],
      min_height: [type: :pos_integer],
      fit: [type: {:in, [:contain, :cover, :cover_down, :stretch, :auto]}],
      enlarge: [type: :boolean],
      zoom: [type: custom(:zoom)]
    ]
  end

  defp custom(kind), do: {:custom, Values, :cast, [kind]}

  defp validate!(options, schema) do
    case validate(options, schema) do
      {:ok, values} -> Map.new(values)
      {:error, message} -> raise ArgumentError, message
    end
  end

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
