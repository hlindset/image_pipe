defmodule ImagePipe.Parser.Imgproxy.Options do
  @moduledoc false

  alias ImagePipe.Parser.Imgproxy.OptionGrammar
  alias ImagePipe.Parser.Imgproxy.Orientation
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.PipelineRequest
  alias ImagePipe.Parser.Imgproxy.Presets
  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Output.QualitySearch

  # Default SSIMULACRA2 target when an `:ssim2` search is active but neither the
  # URL nor host config supplies one. Sized to the "very high quality" tier
  # (≈ imgproxy's DSSIM-0.02 intent) and chosen below the tightest default cap
  # ceiling so the search lands in-bracket rather than pinning best-effort —
  # see `docs/imgproxy_support_matrix.md` (Autoquality and byte-budget search).
  # Metric-specific on purpose: `:size`'s target is a byte count, which has
  # no sane default, so it stays required.
  @default_ssim2_target 78

  # Default butteraugli distance target (≈ visually lossless) when a butteraugli
  # search is active but neither URL nor host config supplies one.
  @default_butteraugli_target 1.0

  @effect_fields [
    :blur,
    :sharpen,
    :pixelate,
    :monochrome,
    :duotone,
    :brightness,
    :contrast,
    :saturation,
    :colorize,
    :gradient
  ]

  @type request_options :: %{
          pipelines: [PipelineRequest.t()],
          auto_rotate: boolean(),
          output: ParsedRequest.output_request(),
          policy: ParsedRequest.policy_request(),
          cache: ParsedRequest.cache_request(),
          response: ParsedRequest.response_request()
        }

  @spec parse([String.t()], Presets.t(), keyword()) :: {:ok, request_options()} | {:error, term()}
  def parse(option_segments, %Presets{} = presets, defaults \\ []) when is_list(defaults) do
    with {:ok, options} <- initial_request_options() |> apply_default_preset(presets),
         {:ok, options} <- apply_segments(option_segments, options, presets, []),
         {:ok, options} <- drain_queued_preset_groups(options, presets),
         {:ok, options} <-
           options |> finalize_request_options() |> apply_request_defaults(defaults) do
      request = Map.take(options, [:pipelines, :auto_rotate, :output, :policy, :cache, :response])

      {:ok, request}
    end
  end

  defp initial_request_options do
    %{
      current_pipeline: %PipelineRequest{},
      queued_preset_groups: [],
      pipelines: [],
      output: ParsedRequest.output_request(),
      policy: ParsedRequest.policy_request(),
      cache: ParsedRequest.cache_request(),
      response: ParsedRequest.response_request()
    }
  end

  defp finalize_request_options(options) do
    options = finalize_current_pipeline(options)
    pipelines = Enum.reverse(options.pipelines)

    pipelines =
      if pipelines == [] do
        [%PipelineRequest{}]
      else
        pipelines
      end

    %{
      options
      | current_pipeline: %PipelineRequest{},
        queued_preset_groups: [],
        pipelines: pipelines
    }
  end

  defp apply_default_preset(options, %Presets{} = presets) do
    case Presets.fetch(presets, "default") do
      {:ok, groups} -> apply_preset_groups(groups, options, presets, ["default"])
      :error -> {:ok, options}
    end
  end

  defp apply_segments(segments, options, presets, active_presets) do
    Enum.reduce_while(segments, {:ok, options}, fn segment, {:ok, options} ->
      case apply_segment(segment, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_segment("-", options, presets, _active_presets) do
    options
    |> finalize_current_pipeline()
    |> apply_next_queued_preset_group(presets)
  end

  defp apply_segment(segment, options, presets, active_presets) do
    case OptionGrammar.parse(segment) do
      {:ok, {:preset, names}} ->
        apply_preset_names(names, options, presets, active_presets)

      {:ok, {:pipeline, assignments}} ->
        {:ok, update_current_pipeline(options, assignments)}

      {:ok, {:output, assignments}} ->
        {:ok, update_output(options, assignments)}

      {:ok, {:cache, assignments}} ->
        {:ok, update_cache(options, assignments)}

      {:ok, {:policy, assignments}} ->
        {:ok, update_policy(options, assignments)}

      {:ok, {:response, assignments}} ->
        {:ok, update_response(options, assignments)}

      {:error, _reason} = error ->
        error
    end
  end

  defp apply_preset_names(names, options, presets, active_presets) do
    Enum.reduce_while(names, {:ok, options}, fn name, {:ok, options} ->
      case apply_preset(name, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_preset(name, options, presets, active_presets) do
    case name in active_presets do
      true ->
        {:ok, options}

      false ->
        case Presets.fetch(presets, name) do
          {:ok, groups} -> apply_preset_groups(groups, options, presets, [name | active_presets])
          :error -> {:error, {:unknown_preset, name}}
        end
    end
  end

  defp apply_preset_groups([first_group | remaining_groups], options, presets, active_presets) do
    with {:ok, options} <- apply_segments(first_group, options, presets, active_presets) do
      {:ok, enqueue_preset_groups(options, remaining_groups, active_presets)}
    end
  end

  defp enqueue_preset_groups(options, [], _active_presets), do: options

  defp enqueue_preset_groups(%{queued_preset_groups: queue} = options, groups, active_presets) do
    levels = Enum.map(groups, &[{&1, active_presets}])
    %{options | queued_preset_groups: merge_queued_preset_levels(queue, levels)}
  end

  defp apply_next_queued_preset_group(%{queued_preset_groups: []} = options, _presets),
    do: {:ok, options}

  defp apply_next_queued_preset_group(
         %{queued_preset_groups: [entries | queue]} = options,
         presets
       ) do
    %{options | queued_preset_groups: queue}
    |> apply_queued_preset_entries(entries, presets)
  end

  defp apply_queued_preset_entries(options, entries, presets) do
    Enum.reduce_while(entries, {:ok, options}, fn {segments, active_presets}, {:ok, options} ->
      case apply_segments(segments, options, presets, active_presets) do
        {:ok, options} -> {:cont, {:ok, options}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp merge_queued_preset_levels([], levels), do: levels
  defp merge_queued_preset_levels(queue, []), do: queue

  defp merge_queued_preset_levels([queue_level | queue], [new_level | levels]) do
    [queue_level ++ new_level | merge_queued_preset_levels(queue, levels)]
  end

  defp drain_queued_preset_groups(%{queued_preset_groups: []} = options, _presets),
    do: {:ok, options}

  defp drain_queued_preset_groups(options, presets) do
    with {:ok, options} <-
           options
           |> finalize_current_pipeline()
           |> apply_next_queued_preset_group(presets) do
      drain_queued_preset_groups(options, presets)
    end
  end

  defp finalize_current_pipeline(%{current_pipeline: pipeline, pipelines: pipelines} = options) do
    if pipeline_empty?(pipeline) do
      %{options | current_pipeline: %PipelineRequest{}}
    else
      %{options | current_pipeline: %PipelineRequest{}, pipelines: [pipeline | pipelines]}
    end
  end

  defp update_current_pipeline(%{current_pipeline: pipeline} = options, assignments) do
    pipeline =
      Enum.reduce(assignments, pipeline, fn
        {:orientation, orientation_assignments}, pipeline ->
          %{
            pipeline
            | orientation: struct!(pipeline.orientation, orientation_assignments),
              orientation_requested: true,
              auto_rotate_requested:
                pipeline.auto_rotate_requested or
                  Keyword.has_key?(orientation_assignments, :auto_orient)
          }

        {:padding, padding_args}, pipeline ->
          apply_padding(pipeline, padding_args)

        {:background_color, color}, pipeline ->
          apply_background_color(pipeline, color)

        {:background_alpha, alpha}, pipeline ->
          apply_background_alpha(pipeline, alpha)

        {:trim, trim_assignments}, pipeline ->
          %{pipeline | trim: trim_assignments}

        {field, _value} = assignment, pipeline when field in @effect_fields ->
          %{pipeline | effects: struct!(pipeline.effects, [assignment])}

        {:strip_color_profile, value}, pipeline ->
          %{pipeline | strip_color_profile: value, strip_color_profile_requested: true}

        {:color_profile, value}, pipeline ->
          %{pipeline | color_profile: value}

        assignment, pipeline ->
          struct!(pipeline, [assignment])
      end)

    %{options | current_pipeline: pipeline}
  end

  defp update_output(%{output: output} = options, assignments) do
    output =
      Enum.reduce(assignments, output, fn
        {:format_qualities, format_qualities}, output ->
          %{
            output
            | format_qualities: Map.merge(output.format_qualities, format_qualities)
          }

        assignment, output ->
          merge_request_map(output, [assignment])
      end)

    %{options | output: output}
  end

  defp update_cache(%{cache: cache} = options, assignments) do
    %{options | cache: merge_request_map(cache, assignments)}
  end

  defp update_policy(%{policy: policy} = options, assignments) do
    %{options | policy: merge_request_map(policy, assignments)}
  end

  defp update_response(%{response: response} = options, assignments) do
    %{options | response: merge_request_map(response, assignments)}
  end

  defp merge_request_map(request, assignments) do
    attrs = Map.new(assignments)
    unknown_keys = Map.keys(attrs) -- Map.keys(request)

    case unknown_keys do
      [] -> Map.merge(request, attrs)
      keys -> raise ArgumentError, "unknown request keys: #{inspect(keys)}"
    end
  end

  defp pipeline_empty?(%PipelineRequest{} = pipeline) do
    normalize_empty_pipeline_values(pipeline) == %PipelineRequest{}
  end

  defp normalize_empty_pipeline_values(%PipelineRequest{} = pipeline) do
    %{
      pipeline
      | gravity_x_offset: normalize_zero_offset(pipeline.gravity_x_offset),
        gravity_y_offset: normalize_zero_offset(pipeline.gravity_y_offset)
    }
  end

  defp normalize_zero_offset(offset) when is_float(offset) and offset == 0.0,
    do: {:pixels, 0.0}

  defp normalize_zero_offset(offset), do: offset

  defp apply_request_defaults(%{pipelines: pipelines, output: output} = options, defaults) do
    auto_rotate? = effective_auto_rotate(pipelines, Keyword.get(defaults, :auto_rotate, false))

    strip_color_profile? =
      effective_strip_color_profile(pipelines, Keyword.get(defaults, :strip_color_profile, true))

    color_profile = effective_color_profile(pipelines)

    pipelines =
      pipelines
      |> Enum.map(fn pipeline ->
        pipeline
        |> consume_auto_rotate_request()
        |> consume_strip_color_profile_request()
        |> consume_color_profile_request()
      end)
      |> apply_strip_color_profile_to_first_pipeline(strip_color_profile?)
      |> reject_empty_pipelines()

    with {:ok, output} <-
           output
           |> resolve_metadata_defaults(defaults)
           |> Map.put(:strip_color_profile, strip_color_profile?)
           |> Map.put(:color_profile, color_profile)
           |> resolve_quality_search_defaults(defaults) do
      options =
        options
        |> Map.put(:auto_rotate, auto_rotate?)
        |> Map.merge(%{pipelines: pipelines, output: output})

      {:ok, options}
    end
  end

  @doc false
  @spec resolve_quality_search_defaults(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def resolve_quality_search_defaults(output, defaults) do
    case effective_quality_search_method(output.quality_search, defaults) do
      :none ->
        {:ok, %{output | quality_search: :none}}

      metric ->
        build_quality_search(
          metric,
          url_quality_search_fields(output.quality_search),
          defaults
        )
        |> case do
          {:ok, search} -> {:ok, %{output | quality_search: search}}
          {:error, _reason} = error -> error
        end
    end
  end

  defp effective_quality_search_method({:autoquality, :disabled}, _defaults), do: :none

  defp effective_quality_search_method({:autoquality, fields}, defaults) when is_list(fields),
    do: Keyword.get(fields, :metric, Keyword.get(defaults, :autoquality_method, :none))

  defp effective_quality_search_method(:none, defaults),
    do: Keyword.get(defaults, :autoquality_method, :none)

  defp url_quality_search_fields({:autoquality, fields}) when is_list(fields), do: fields
  defp url_quality_search_fields(_quality_search), do: []

  defp build_quality_search(:size, fields, defaults) do
    with {:ok, target} <- resolve_quality_search_target(:size, fields, defaults) do
      {:ok,
       %QualitySearch.Size{
         target: target,
         min_quality:
           Keyword.get(fields, :min_quality, Keyword.get(defaults, :autoquality_min_quality, 70)),
         max_quality:
           Keyword.get(fields, :max_quality, Keyword.get(defaults, :autoquality_max_quality, 80)),
         format_min: Keyword.get(defaults, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(defaults, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(defaults, :autoquality_max_resolution, 0)
       }}
    end
  end

  defp build_quality_search(:ssimulacra2, fields, defaults),
    do:
      build_quality_metric(QualitySearch.Ssimulacra2, :ssimulacra2, fields, defaults, 70, 80, 1.0)

  defp build_quality_search(:butteraugli, fields, defaults),
    do:
      build_quality_metric(QualitySearch.Butteraugli, :butteraugli, fields, defaults, 1, 100, 0.1)

  defp build_quality_metric(
         struct_mod,
         metric,
         fields,
         defaults,
         default_min,
         default_max,
         default_error
       ) do
    with {:ok, target} <- resolve_quality_search_target(metric, fields, defaults) do
      {:ok,
       struct(struct_mod, %{
         target: target,
         min_quality:
           Keyword.get(
             fields,
             :min_quality,
             Keyword.get(defaults, :autoquality_min_quality, default_min)
           ),
         max_quality:
           Keyword.get(
             fields,
             :max_quality,
             Keyword.get(defaults, :autoquality_max_quality, default_max)
           ),
         allowed_error:
           Keyword.get(
             fields,
             :allowed_error,
             Keyword.get(defaults, :autoquality_allowed_error, default_error)
           ),
         format_min: Keyword.get(defaults, :autoquality_format_min_quality, %{}),
         format_max: Keyword.get(defaults, :autoquality_format_max_quality, %{}),
         max_resolution: Keyword.get(defaults, :autoquality_max_resolution, 0)
       })}
    end
  end

  defp resolve_quality_search_target(metric, fields, defaults) do
    case Keyword.get(fields, :target, Keyword.get(defaults, :autoquality_target)) do
      nil -> default_target(metric)
      target -> validate_target_range(metric, target)
    end
  end

  # :size target is a byte count. The URL `:target_bytes` field already enforces a
  # positive integer, but a host-config `autoquality_target` is only schema-checked
  # as a number ({:integer | :float}), so re-assert positive-integer bytes here to
  # reject a misconfigured `0`, negative, or fractional byte budget.
  defp validate_target_range(:size, target) when is_integer(target) and target > 0,
    do: {:ok, target}

  defp validate_target_range(:size, target),
    do: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}

  defp validate_target_range(metric, target) do
    {lo, hi} = metric_target_range(metric)

    if is_number(target) and target >= lo and target <= hi,
      do: {:ok, target},
      else: {:error, {:invalid_option, :autoquality, {:target_out_of_range, target}}}
  end

  # Mirrors Output.Metric.*.target_range/0 (parser may not depend on Output; same
  # precedent as :target_float's inline 0–100 clamp).
  defp metric_target_range(:ssimulacra2), do: {0.0, 100.0}
  defp metric_target_range(:butteraugli), do: {0.0, 25.0}

  defp default_target(:ssimulacra2), do: {:ok, @default_ssim2_target}
  defp default_target(:butteraugli), do: {:ok, @default_butteraugli_target}
  defp default_target(_metric), do: {:error, {:invalid_option, :autoquality, :missing_target}}

  defp resolve_metadata_defaults(output, defaults) do
    strip = resolve_bool(output.strip_metadata, Keyword.get(defaults, :strip_metadata, true))
    keep = resolve_bool(output.keep_copyright, Keyword.get(defaults, :keep_copyright, true))
    preserve_hdr = resolve_bool(output.preserve_hdr, Keyword.get(defaults, :preserve_hdr, false))
    # keep_copyright is only meaningful when metadata is being stripped; force it
    # false otherwise so byte-identical outputs share one canonical cache key.
    %{output | strip_metadata: strip, keep_copyright: strip and keep, preserve_hdr: preserve_hdr}
  end

  defp resolve_bool(nil, default), do: default
  defp resolve_bool(value, _default) when is_boolean(value), do: value

  defp effective_auto_rotate(pipelines, default) do
    Enum.reduce(pipelines, default, fn
      %PipelineRequest{
        auto_rotate_requested: true,
        orientation: %Orientation{auto_orient: auto_rotate?}
      },
      _auto_rotate? ->
        auto_rotate?

      %PipelineRequest{}, auto_rotate? ->
        auto_rotate?
    end)
  end

  defp consume_auto_rotate_request(
         %PipelineRequest{orientation: %Orientation{} = orientation} = pipeline
       ) do
    orientation = %Orientation{orientation | auto_orient: false}

    %{
      pipeline
      | orientation: orientation,
        orientation_requested: orientation_requested?(orientation),
        auto_rotate_requested: false
    }
  end

  defp effective_strip_color_profile(pipelines, default) do
    Enum.reduce(pipelines, default, fn
      %PipelineRequest{strip_color_profile_requested: true, strip_color_profile: value}, _acc ->
        value

      %PipelineRequest{}, acc ->
        acc
    end)
  end

  defp consume_strip_color_profile_request(%PipelineRequest{} = pipeline),
    do: %{pipeline | strip_color_profile: false, strip_color_profile_requested: false}

  defp effective_color_profile(pipelines) do
    Enum.reduce(pipelines, nil, fn
      %PipelineRequest{color_profile: target}, _acc when not is_nil(target) -> target
      %PipelineRequest{}, acc -> acc
    end)
  end

  defp consume_color_profile_request(%PipelineRequest{} = pipeline),
    do: %{pipeline | color_profile: nil}

  defp apply_strip_color_profile_to_first_pipeline(pipelines, false), do: pipelines

  defp apply_strip_color_profile_to_first_pipeline([first | rest], true),
    do: [%{first | strip_color_profile: true} | rest]

  defp reject_empty_pipelines(pipelines) do
    case Enum.reject(pipelines, &pipeline_empty?/1) do
      [] -> [%PipelineRequest{}]
      pipelines -> pipelines
    end
  end

  defp orientation_requested?(%Orientation{} = orientation), do: orientation != %Orientation{}

  defp apply_padding(%PipelineRequest{} = pipeline, values) do
    top = padding_value(Enum.at(values, 0), pipeline.padding_top)
    right = padding_value(Enum.at(values, 1), fallback_padding(top, pipeline.padding_right))
    bottom = padding_value(Enum.at(values, 2), fallback_padding(top, pipeline.padding_bottom))
    left = padding_value(Enum.at(values, 3), fallback_padding(right, pipeline.padding_left))

    %{
      pipeline
      | padding_top: top,
        padding_right: right,
        padding_bottom: bottom,
        padding_left: left
    }
  end

  defp padding_value(nil, current), do: current
  defp padding_value(:unset, current), do: current
  defp padding_value(value, _current) when is_integer(value), do: value

  defp fallback_padding(:unset, current), do: current
  defp fallback_padding(value, _current), do: value

  defp apply_background_color(%PipelineRequest{} = pipeline, nil) do
    %{pipeline | background_color: nil, background_alpha: nil}
  end

  defp apply_background_color(%PipelineRequest{} = pipeline, %Color{} = color) do
    %{pipeline | background_color: color_with_alpha!(color, pipeline.background_alpha)}
  end

  defp apply_background_alpha(%PipelineRequest{} = pipeline, alpha) do
    color =
      pipeline.background_color
      |> default_background_color()
      |> color_with_alpha!(alpha)

    %{pipeline | background_color: color, background_alpha: alpha}
  end

  defp default_background_color(nil) do
    {:ok, black} = Color.rgb(0, 0, 0)
    black
  end

  defp default_background_color(%Color{} = color), do: color

  defp color_with_alpha!(%Color{} = color, nil), do: color

  defp color_with_alpha!(%Color{} = color, alpha) do
    {:ok, color} = Color.with_alpha(color, alpha)
    color
  end
end
