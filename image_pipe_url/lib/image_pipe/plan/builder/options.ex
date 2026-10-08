defmodule ImagePipe.Plan.Builder.Options do
  @moduledoc false

  alias ImagePipe.Plan.Builder.OutputOptions
  alias ImagePipe.Plan.Builder.Values
  alias ImagePipe.Plan.Spec.Issue

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

  # Options whose value may start with `:unset` to clear lower layers first.
  @layered [:format_qualities, :jpeg_options, :png_options, :webp_options, :avif_options]

  @docs "https://hexdocs.pm/image_pipe"

  # Each function returns the options it accepts, the issues it found, and
  # each rejected option's location and value. Locations name request
  # options `{:request, key}`.
  def request(options),
    do: collect(options, validators(:request, &request_schema/0), &{:request, &1})

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

  # Returns `:empty` for a group with no options and no errors.
  def group(options, index) do
    location = &{:group, index, &1}

    {group, issues, rejected} =
      collect(options, validators(:group, &group_schema/0), location,
        unsettable: compiled(:transform_keys, fn -> Keyword.keys(transform_schema()) end),
        flat: [:resize]
      )

    {resize, group} = Map.pop(group, :resize, [])
    group = if Map.get(group, :presets) == [], do: Map.delete(group, :presets), else: group

    {resize, resize_issues, resize_rejected} =
      collect(resize, validators(:resize, &resize_schema/0), location)

    issues = issues ++ resize_issues
    rejected = rejected ++ resize_rejected

    case Map.merge(group, resize) do
      values when map_size(values) == 0 and rejected == [] -> {:empty, issues, []}
      values -> {values, issues, rejected}
    end
  end

  def output(options),
    do: collect(options, validators(:output, &OutputOptions.schema/0), &{:request, &1})

  def output_option?(key),
    do: Map.has_key?(validators(:output, &OutputOptions.schema/0), key)

  # Validating against a keyword schema first validates the schema itself, so
  # each fixed schema is compiled once and kept for the VM's lifetime.
  @doc false
  def compiled(name, build) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        value = build.()
        :persistent_term.put(key, value)
        value

      value ->
        value
    end
  end

  @doc false
  def compiled_schema(name, schema),
    do: compiled({:schema, name}, fn -> NimbleOptions.new!(schema.()) end)

  # Each option of a schema compiled on its own, so one invalid option
  # rejects only itself.
  defp validators(name, schema) do
    compiled({:validators, name}, fn ->
      Map.new(schema.(), fn {key, spec} -> {key, NimbleOptions.new!([{key, spec}])} end)
    end)
  end

  # Every option accepts `:unset`, which clears it from presets and request
  # defaults. Unset options skip validation, so an error lists only the
  # values the option really takes. A mistake with one clear meaning is
  # repaired with a warning, and any other rejects only its own option.
  # `:flat` names keyword options checked by their own schema later.
  defp collect(options, validators, location, opts \\ []) do
    unless is_list(options) and Keyword.keyword?(options),
      do: raise(ArgumentError, "expected a keyword list, got: #{inspect(options)}")

    unsettable = Keyword.get_lazy(opts, :unsettable, fn -> Map.keys(validators) end)
    {options, repeated} = last_values(options, location, Keyword.get(opts, :flat, []))

    {values, issues, rejected} =
      Enum.reduce(options, {%{}, [], []}, fn {key, value}, {values, issues, rejected} ->
        {value, unset_issues} = collapse_unset(key, value, location)

        case check(key, value, validators, unsettable, location) do
          {:ok, checked} ->
            {Map.put(values, key, checked), issues ++ unset_issues, rejected}

          {:error, issue} ->
            {values, issues ++ unset_issues ++ [issue], rejected ++ [{location.(key), value}]}
        end
      end)

    {values, repeated ++ issues, rejected}
  end

  defp check(key, :unset, validators, unsettable, location) do
    case key in unsettable do
      true -> {:ok, :unset}
      false -> check_value(key, :unset, validators, location)
    end
  end

  defp check(key, value, validators, _unsettable, location),
    do: check_value(key, value, validators, location)

  defp check_value(key, value, validators, location) do
    case Map.fetch(validators, key) do
      {:ok, schema} ->
        case NimbleOptions.validate([{key, value}], schema) do
          {:ok, [{^key, value}]} ->
            {:ok, value}

          {:error, error} ->
            {:error, issue(:invalid_value, location.(key), Exception.message(error))}
        end

      :error ->
        {:error, issue(:unknown_option, location.(key), nil)}
    end
  end

  # A name given twice keeps its last value, at every level of nesting.
  defp last_values(options, location, flat) do
    keys = Keyword.keys(options)
    repeated = keys |> Enum.frequencies() |> Map.filter(fn {_key, n} -> n > 1 end)

    options =
      options
      |> Enum.reverse()
      |> Enum.uniq_by(&elem(&1, 0))
      |> Enum.reverse()
      |> Enum.map(fn {key, value} ->
        case key in flat do
          true -> {key, value, false}
          false -> Tuple.insert_at(nested_last_values(value), 0, key)
        end
      end)

    issues =
      for {key, _value, nested?} <- options,
          Map.has_key?(repeated, key) or nested?,
          do: issue(:repeated_option, location.(key), nil, :warning)

    {Enum.map(options, fn {key, value, _nested?} -> {key, value} end), issues}
  end

  defp nested_last_values([_ | _] = value) do
    {unsets, rest} = Enum.split_while(value, &(&1 == :unset))

    case rest != [] and Keyword.keyword?(rest) do
      true ->
        {rest, repeated?} =
          Enum.map_reduce(Enum.reverse(rest) |> Enum.uniq_by(&elem(&1, 0)), false, fn
            {key, value}, repeated? ->
              {value, nested?} = nested_last_values(value)
              {{key, value}, repeated? or nested?}
          end)

        {unsets ++ Enum.reverse(rest), repeated? or length(rest) < length(value) - length(unsets)}

      false ->
        {value, false}
    end
  end

  defp nested_last_values(value), do: {value, false}

  # A lone `:unset` in a list means the same as `:unset`, and a repeated
  # leading `:unset` the same as one.
  defp collapse_unset(key, [:unset | _] = value, location) when key in @layered do
    case Enum.split_while(value, &(&1 == :unset)) do
      {_unsets, []} ->
        {:unset, [issue(:redundant_unset, location.(key), nil, :warning)]}

      {[_], _rest} ->
        {value, []}

      {_unsets, rest} ->
        {[:unset | rest], [issue(:redundant_unset, location.(key), nil, :warning)]}
    end
  end

  defp collapse_unset(_key, value, _location), do: {value, []}

  defp issue(reason, location, detail, severity \\ :error),
    do: %Issue{reason: reason, locations: [location], detail: detail, severity: severity}

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
      dpr: [type: custom(:scale_factor)],
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
      blur: [type: custom(:blur)],
      progressive_blur: [type: custom(:progressive_blur)],
      sharpen: [type: custom(:sharpen)],
      pixelate: [type: custom(:axis)],
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
      width: [type: custom(:dimension)],
      height: [type: custom(:dimension)],
      min_width: [type: custom(:axis)],
      min_height: [type: custom(:axis)],
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
