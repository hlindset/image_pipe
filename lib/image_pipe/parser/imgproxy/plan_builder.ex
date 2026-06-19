defmodule ImagePipe.Parser.Imgproxy.PlanBuilder do
  @moduledoc false

  alias ImagePipe.Format
  alias ImagePipe.Parser.Imgproxy.CropRequest
  alias ImagePipe.Parser.Imgproxy.Effects
  alias ImagePipe.Parser.Imgproxy.Orientation
  alias ImagePipe.Parser.Imgproxy.ParsedRequest
  alias ImagePipe.Parser.Imgproxy.PipelineRequest
  alias ImagePipe.Parser.Imgproxy.Source, as: ImgproxySource
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Plan.Source.Reference
  alias ImagePipe.Plan.Source.URL

  @default_gravity {:anchor, :center, :center}

  alias ImagePipe.Parser.Imgproxy.InfoRenderer

  @spec to_plan(ParsedRequest.t(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(request, opts \\ [])

  def to_plan(%ParsedRequest{info?: true} = request, opts) do
    with {:ok, source} <- source_plan(request.source_kind, request.source_path, opts),
         {:ok, expires} <- expires_plan(request.policy, opts),
         {:ok, cachebuster} <- cachebuster_plan(request.cache) do
      {:ok,
       %Plan{
         source: source,
         auto_rotate: false,
         pipelines: [],
         output: nil,
         expires: expires,
         cachebuster: cachebuster,
         response: %Response{},
         render: {:custom, InfoRenderer, %{}}
       }}
    end
  end

  def to_plan(%ParsedRequest{} = request, opts) do
    imgproxy_opts = Keyword.get(opts, :imgproxy, [])
    face_assist? = Keyword.get(imgproxy_opts, :smart_crop_face_detection, false)

    with {:ok, source} <- source_plan(request.source_kind, request.source_path, opts),
         {:ok, output} <- output_plan(request.output),
         {:ok, expires} <- expires_plan(request.policy, opts),
         {:ok, cachebuster} <- cachebuster_plan(request.cache),
         {:ok, response} <- response_plan(request.response, source),
         {:ok, pipelines} <- build_pipelines(request.pipelines, face_assist?) do
      {:ok,
       %Plan{
         source: source,
         auto_rotate: request.auto_rotate,
         pipelines: pipelines,
         output: output,
         expires: expires,
         cachebuster: cachebuster,
         response: response
       }}
    end
  end

  defp source_plan(:plain, source_identifier, opts) when is_binary(source_identifier),
    do: ImgproxySource.translate(source_identifier, Keyword.get(opts, :imgproxy, []))

  defp source_plan(kind, _source_identifier, _opts),
    do: {:error, {:unsupported_source_kind, kind}}

  defp build_pipelines([], _face_assist?), do: {:error, :empty_pipeline_plan}

  defp build_pipelines(pipeline_requests, face_assist?) do
    result =
      Enum.reduce_while(pipeline_requests, [], fn pipeline_request, pipelines ->
        stamped = %{pipeline_request | smart_crop_face_detection: face_assist?}

        case pipeline(stamped) do
          {:ok, pipeline} -> {:cont, [pipeline | pipelines]}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)

    case result do
      {:error, _reason} = error -> error
      pipelines -> {:ok, Enum.reverse(pipelines)}
    end
  end

  defp pipeline(%PipelineRequest{} = pipeline_request) do
    with {:ok, operations} <- plan_geometry(pipeline_request) do
      {:ok, %Pipeline{operations: operations}}
    end
  end

  defp reduce_results(results) do
    result =
      Enum.reduce_while(results, {:ok, []}, fn
        {:ok, value}, {:ok, values} -> {:cont, {:ok, [value | values]}}
        {:error, reason}, {:ok, _values} -> {:halt, {:error, reason}}
      end)

    case result do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, _reason} = error -> error
    end
  end

  defp output_plan(%{format: nil} = request) do
    {:ok,
     %Output{
       mode: :automatic,
       quality: request.quality,
       format_qualities: request.format_qualities,
       strip_metadata: request.strip_metadata,
       keep_copyright: request.keep_copyright,
       color_profile: color_profile_policy(request.color_profile, request.strip_color_profile),
       hdr: hdr_policy(request.preserve_hdr)
     }}
  end

  defp output_plan(%{format: :best}),
    do: {:error, {:unsupported_output_format, :best}}

  defp output_plan(%{format: format} = request) do
    case Format.output_format?(format) do
      true ->
        {:ok,
         %Output{
           mode: {:explicit, format},
           quality: request.quality,
           format_qualities: request.format_qualities,
           strip_metadata: request.strip_metadata,
           keep_copyright: request.keep_copyright,
           color_profile:
             color_profile_policy(request.color_profile, request.strip_color_profile),
           hdr: hdr_policy(request.preserve_hdr)
         }}

      false ->
        {:error, {:unsupported_output_format, format}}
    end
  end

  # A present cp/icc target wins over scp (imgproxy: cp-embedded profiles are not
  # stripped by strip_color_profile). scp only decides strip vs preserve when no
  # target is set.
  defp color_profile_policy(target, _strip) when not is_nil(target), do: {:convert, target}
  defp color_profile_policy(nil, true), do: :strip
  defp color_profile_policy(nil, false), do: :preserve_source
  defp color_profile_policy(nil, nil), do: :strip

  defp hdr_policy(true), do: :preserve
  defp hdr_policy(false), do: :tone_map
  defp hdr_policy(nil), do: :tone_map

  defp expires_plan(%{expires: 0}, _opts), do: {:ok, 0}

  defp expires_plan(%{expires: expires}, opts)
       when is_integer(expires) and expires > 0 do
    with :ok <- reject_expired_request(expires, now_unix_seconds(opts)) do
      {:ok, expires}
    end
  end

  defp reject_expired_request(expires, now) do
    if expires > 0 and expires < now do
      {:error, {:expired_request, expires}}
    else
      :ok
    end
  end

  defp now_unix_seconds(opts) do
    opts
    |> Keyword.get(:clock, &DateTime.utc_now/0)
    |> then(&DateTime.to_unix(&1.()))
  end

  defp cachebuster_plan(%{cachebuster: cachebuster}),
    do: {:ok, cachebuster}

  defp response_plan(
         %{filename: nil, disposition: disposition},
         source
       ) do
    {:ok, %Response{filename: source_filename(source), disposition: disposition}}
  end

  defp response_plan(
         %{filename: filename, disposition: disposition},
         _source
       )
       when is_binary(filename) do
    if Response.valid_filename?(filename) do
      {:ok, %Response{filename: filename, disposition: disposition}}
    else
      {:error, {:invalid_filename, filename}}
    end
  end

  defp source_filename(%Path{segments: segments}), do: filename_from_segments(segments)
  defp source_filename(%URL{path: path}), do: filename_from_segments(path)

  defp source_filename(%Object{key: key}) do
    key
    |> String.split("/", trim: true)
    |> filename_from_segments()
  end

  defp source_filename(%Reference{id: id}), do: valid_source_filename(id)
  defp source_filename(_source), do: "image"

  defp filename_from_segments(segments) do
    segments
    |> List.last()
    |> source_filename_stem()
    |> valid_source_filename()
  end

  defp source_filename_stem(basename) when basename in [nil, ""], do: "image"

  defp source_filename_stem(basename) when is_binary(basename) do
    case Elixir.Path.rootname(basename) do
      "" -> "image"
      stem -> stem
    end
  end

  defp valid_source_filename(stem) do
    if Response.valid_filename?(stem), do: stem, else: "image"
  end

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type, width: nil})
       when resizing_type in [:fill_down, :auto],
       do: missing_dimensions(resizing_type)

  defp plan_geometry(%PipelineRequest{resizing_type: resizing_type, height: nil})
       when resizing_type in [:fill_down, :auto],
       do: missing_dimensions(resizing_type)

  defp plan_geometry(%PipelineRequest{} = request) do
    with {:ok, trim_operations} <- trim_operations(request),
         {:ok, orientation_operations} <- orientation_operations(request),
         {:ok, crop_operations} <- crop_operations(request),
         {:ok, resize_operations} <- resize_operations(request),
         {:ok, effect_operations} <- effect_operations(request),
         {:ok, canvas_operations} <- canvas_operations(request),
         {:ok, padding_operations} <- padding_operations(request),
         {:ok, background_operations} <- background_operations(request) do
      {:ok,
       trim_operations ++
         orientation_operations ++
         crop_operations ++
         resize_operations ++
         effect_operations ++
         canvas_operations ++
         padding_operations ++
         background_operations}
    end
  end

  defp trim_operations(%PipelineRequest{trim: nil}), do: {:ok, []}

  defp trim_operations(%PipelineRequest{trim: trim}) do
    with {:ok, operation} <- Operation.trim(trim) do
      {:ok, [operation]}
    end
  end

  defp crop_operations(%PipelineRequest{crop: nil}), do: {:ok, []}

  defp crop_operations(%PipelineRequest{crop: %CropRequest{} = crop} = request) do
    {gravity, x_offset, y_offset} = crop_gravity(crop, request)

    with {:ok, width} <- imgproxy_tagged_crop_dimension(crop.width),
         {:ok, height} <- imgproxy_tagged_crop_dimension(crop.height),
         {:ok, guide} <- tagged_gravity(gravity, request.smart_crop_face_detection),
         {:ok, operation} <-
           Operation.crop_guided(
             width,
             height,
             guide,
             x_offset: x_offset,
             y_offset: y_offset,
             aspect_ratio: crop_aspect_ratio(request),
             enlarge: request.crop_aspect_ratio_enlarge
           ) do
      {:ok, [operation]}
    end
  end

  # A bare crop (`c:W:H` with no inline gravity args) inherits the ENTIRE top-level `g:`
  # option — both the type and its x/y offsets — per imgproxy's crop semantics ("when
  # gravity is not set, it will use the value of the gravity option"). An inline crop
  # gravity (`c:W:H:type[:x:y]`) fully specifies its own gravity, so its own offsets are
  # used (a crop can't carry offsets without an inline type, so `gravity: nil` always
  # means zero crop offsets).
  defp crop_gravity(%CropRequest{gravity: nil}, %PipelineRequest{} = request),
    do: {request.gravity, request.gravity_x_offset, request.gravity_y_offset}

  defp crop_gravity(%CropRequest{} = crop, %PipelineRequest{}),
    do: {crop.gravity, crop.x_offset, crop.y_offset}

  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: nil}), do: nil
  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: ratio}) when ratio == 0.0, do: nil

  defp crop_aspect_ratio(%PipelineRequest{crop_aspect_ratio: ratio}) do
    {:ok, tagged} = tagged_ratio_from_decimal(ratio)
    tagged
  end

  defp orientation_operations(%PipelineRequest{orientation: %Orientation{} = orientation}) do
    operations =
      [
        rotate_operation(orientation),
        flip_operation(orientation)
      ]
      |> Enum.reject(&is_nil/1)

    reduce_results(operations)
  end

  defp rotate_operation(%Orientation{rotate: 0}), do: nil

  defp rotate_operation(%Orientation{rotate: angle}) when angle in [90, 180, 270],
    do: Operation.rotate(angle)

  defp flip_operation(%Orientation{flip: nil}), do: nil

  defp flip_operation(%Orientation{flip: axis}) when axis in [:horizontal, :vertical, :both],
    do: Operation.flip(axis)

  defp resize_operations(%PipelineRequest{width: nil, height: nil} = request) do
    if resize_rule_requested?(request) do
      resize_from_rule(request)
    else
      {:ok, []}
    end
  end

  defp resize_operations(%PipelineRequest{width: {:pixels, 0}, height: {:pixels, 0}} = request) do
    if resize_rule_requested?(request) do
      resize_from_rule(request)
    else
      {:ok, []}
    end
  end

  defp resize_operations(%PipelineRequest{resizing_type: :auto} = request) do
    with {:ok, operation} <- resize_operation(request) do
      {:ok, [operation]}
    end
  end

  defp resize_operations(%PipelineRequest{resizing_type: resizing_type} = request)
       when resizing_type in [:fit, :fill, :fill_down, :force] do
    resize_from_rule(request)
  end

  defp resize_from_rule(%PipelineRequest{} = request) do
    with {:ok, width} <- imgproxy_resize_dimension(request.width),
         {:ok, height} <- imgproxy_resize_dimension(request.height) do
      resize_operations_for(request, width, height)
    end
  end

  defp resize_operations_for(request, width, height) do
    case {width, height, resize_rule_requested?(request)} do
      {:auto, :auto, false} ->
        {:ok, []}

      {_planned_width, _planned_height, _rule_requested?} ->
        with {:ok, operation} <- resize_operation(request) do
          {:ok, [operation]}
        end
    end
  end

  defp resize_rule_requested?(%PipelineRequest{} = request) do
    not is_nil(request.min_width) or
      not is_nil(request.min_height) or
      not is_nil(request.zoom_x) or
      not is_nil(request.zoom_y) or
      not is_nil(request.dpr)
  end

  defp canvas_operations(%PipelineRequest{} = request) do
    operations =
      [
        extend_operation(request),
        extend_aspect_ratio_operation(request)
      ]
      |> Enum.reject(&is_nil/1)

    reduce_results(operations)
  end

  defp extend_operation(%PipelineRequest{} = request) do
    if extend_operation_requested?(request) do
      with {:ok, width} <- imgproxy_canvas_dimension(request.width),
           {:ok, height} <- imgproxy_canvas_dimension(request.height),
           {:ok, placement} <- canvas_placement(request.extend_gravity || @default_gravity) do
        Operation.canvas(
          width,
          height,
          placement,
          fill: :transparent,
          overflow: :reject,
          x_offset: request.extend_x_offset || 0.0,
          y_offset: request.extend_y_offset || 0.0
        )
      end
    end
  end

  defp extend_operation_requested?(%PipelineRequest{extend: false, extend_requested: true}),
    do: false

  defp extend_operation_requested?(%PipelineRequest{} = request) do
    request.extend == true or
      not is_nil(request.extend_gravity) or
      not is_nil(request.extend_x_offset) or
      not is_nil(request.extend_y_offset)
  end

  defp extend_aspect_ratio_operation(%PipelineRequest{} = request) do
    with true <- extend_aspect_ratio_requested?(request),
         {:ok, {ratio_w, ratio_h}} <- resize_target_ratio(request),
         placement_gravity = request.extend_aspect_ratio_gravity || @default_gravity,
         {:ok, placement} <- canvas_placement(placement_gravity) do
      Operation.canvas(
        {:ratio, ratio_w, 1},
        {:ratio, ratio_h, 1},
        placement,
        fill: :transparent,
        overflow: :reject,
        x_offset: request.extend_aspect_ratio_x_offset || 0.0,
        y_offset: request.extend_aspect_ratio_y_offset || 0.0
      )
    else
      false -> nil
      :no_ratio -> nil
      {:error, _reason} = error -> error
    end
  end

  defp extend_aspect_ratio_requested?(%PipelineRequest{extend_aspect_ratio: extend?}), do: extend?

  defp extend_aspect_ratio_emits?(%PipelineRequest{} = request) do
    extend_aspect_ratio_requested?(request) and match?({:ok, _}, resize_target_ratio(request))
  end

  defp resize_target_ratio(%PipelineRequest{width: {:pixels, w}, height: {:pixels, h}})
       when w > 0 and h > 0,
       do: {:ok, {w, h}}

  defp resize_target_ratio(%PipelineRequest{}), do: :no_ratio

  defp padding_operations(%PipelineRequest{
         padding_top: 0,
         padding_right: 0,
         padding_bottom: 0,
         padding_left: 0
       }),
       do: {:ok, []}

  defp padding_operations(
         %PipelineRequest{
           padding_top: top,
           padding_right: right,
           padding_bottom: bottom,
           padding_left: left
         } = request
       ) do
    with {:ok, operation} <-
           Operation.padding(
             {:px, top},
             {:px, right},
             {:px, bottom},
             {:px, left},
             pixel_ratio: effective_padding_pixel_ratio(request),
             fill: :transparent
           ) do
      {:ok, [operation]}
    end
  end

  defp background_operations(%PipelineRequest{background_color: nil}), do: {:ok, []}

  defp background_operations(%PipelineRequest{background_color: color}) do
    with {:ok, operation} <- Operation.background(color) do
      {:ok, [operation]}
    end
  end

  defp effect_operations(%PipelineRequest{effects: %Effects{} = effects}) do
    [
      blur_operation(effects),
      sharpen_operation(effects),
      pixelate_operation(effects),
      monochrome_operation(effects),
      duotone_operation(effects),
      brightness_operation(effects),
      contrast_operation(effects),
      saturation_operation(effects),
      colorize_operation(effects),
      gradient_operation(effects)
    ]
    |> Enum.reject(&is_nil/1)
    |> reduce_results()
  end

  defp blur_operation(%Effects{blur: nil}), do: nil
  defp blur_operation(%Effects{blur: sigma}) when sigma == 0.0, do: nil
  defp blur_operation(%Effects{blur: sigma}), do: Operation.blur(sigma)

  defp sharpen_operation(%Effects{sharpen: nil}), do: nil
  defp sharpen_operation(%Effects{sharpen: sigma}) when sigma == 0.0, do: nil
  defp sharpen_operation(%Effects{sharpen: sigma}), do: Operation.sharpen(sigma)

  defp pixelate_operation(%Effects{pixelate: nil}), do: nil
  defp pixelate_operation(%Effects{pixelate: 0}), do: nil
  defp pixelate_operation(%Effects{pixelate: 1}), do: nil
  defp pixelate_operation(%Effects{pixelate: size}), do: Operation.pixelate(size)

  defp monochrome_operation(%Effects{monochrome: nil}), do: nil

  defp monochrome_operation(%Effects{monochrome: [intensity: {:ratio, 0, _denominator}]}),
    do: nil

  defp monochrome_operation(%Effects{monochrome: monochrome}) do
    Operation.monochrome(
      Keyword.fetch!(monochrome, :intensity),
      Keyword.get_lazy(monochrome, :color, &default_monochrome_color/0)
    )
  end

  defp duotone_operation(%Effects{duotone: nil}), do: nil

  defp duotone_operation(%Effects{duotone: [intensity: {:ratio, 0, _denominator}]}),
    do: nil

  defp duotone_operation(%Effects{duotone: duotone}) do
    Operation.duotone(
      Keyword.fetch!(duotone, :intensity),
      Keyword.get_lazy(duotone, :shadow, &default_duotone_shadow/0),
      Keyword.get_lazy(duotone, :highlight, &default_duotone_highlight/0)
    )
  end

  defp brightness_operation(%Effects{brightness: nil}), do: nil
  defp brightness_operation(%Effects{brightness: 0}), do: nil
  defp brightness_operation(%Effects{brightness: value}), do: Operation.brightness(value)

  defp contrast_operation(%Effects{contrast: nil}), do: nil
  defp contrast_operation(%Effects{contrast: value}) when value == 1.0, do: nil
  defp contrast_operation(%Effects{contrast: value}), do: Operation.contrast(value)

  defp saturation_operation(%Effects{saturation: nil}), do: nil
  defp saturation_operation(%Effects{saturation: value}) when value == 1.0, do: nil
  defp saturation_operation(%Effects{saturation: value}), do: Operation.saturation(value)

  defp colorize_operation(%Effects{colorize: nil}), do: nil

  defp colorize_operation(%Effects{colorize: colorize}) do
    case Keyword.fetch!(colorize, :opacity) do
      {:ratio, 0, _} ->
        nil

      _opacity ->
        Operation.colorize(
          Keyword.fetch!(colorize, :opacity),
          Keyword.get_lazy(colorize, :color, &default_colorize_color/0),
          Keyword.get(colorize, :keep_alpha, false)
        )
    end
  end

  defp gradient_operation(%Effects{gradient: nil}), do: nil

  defp gradient_operation(%Effects{gradient: gradient}) do
    case Keyword.fetch!(gradient, :opacity) do
      {:ratio, 0, _} ->
        nil

      _opacity ->
        Operation.gradient(
          Keyword.fetch!(gradient, :opacity),
          Keyword.get_lazy(gradient, :color, &default_colorize_color/0),
          Keyword.get(gradient, :angle, 0.0),
          Keyword.get(gradient, :start, 0.0),
          Keyword.get(gradient, :stop, 1.0)
        )
    end
  end

  defp resize_operation(%PipelineRequest{} = request) do
    with {:ok, width} <- imgproxy_resize_dimension(request.width),
         {:ok, height} <- imgproxy_resize_dimension(request.height),
         {:ok, min_width} <- optional_resize_dimension(request.min_width),
         {:ok, min_height} <- optional_resize_dimension(request.min_height),
         {:ok, guide} <- resize_guide(request.gravity, request.smart_crop_face_detection) do
      resize_opts = [
        dpr: request.dpr || 1.0,
        down: request.resizing_type == :fill_down,
        enlargement: enlargement(request),
        guide: guide,
        min_width: min_width,
        min_height: min_height,
        zoom_x: request.zoom_x || 1.0,
        zoom_y: request.zoom_y || 1.0
      ]

      Operation.resize(
        resize_mode(request.resizing_type),
        width,
        height,
        resize_opts(request, resize_opts)
      )
    end
  end

  defp resize_opts(%PipelineRequest{resizing_type: resizing_type} = request, opts)
       when resizing_type in [:fill, :fill_down, :auto] do
    Keyword.merge(opts,
      x_offset: request.gravity_x_offset,
      y_offset: request.gravity_y_offset
    )
  end

  defp resize_opts(%PipelineRequest{}, opts), do: opts

  defp resize_mode(:fit), do: :fit
  defp resize_mode(:fill), do: :cover
  defp resize_mode(:fill_down), do: :cover
  defp resize_mode(:force), do: :stretch
  defp resize_mode(:auto), do: :auto

  defp dpr_ratio(%PipelineRequest{dpr: nil}), do: {:ratio, 1, 1}

  defp dpr_ratio(%PipelineRequest{dpr: dpr}) do
    case Operation.resize(:fit, :auto, :auto, dpr: dpr) do
      {:ok, %{dpr: ratio}} -> ratio
    end
  end

  defp effective_padding_pixel_ratio(%PipelineRequest{} = request) do
    mode =
      if extend_operation_requested?(request) or extend_aspect_ratio_emits?(request) do
        :canvas_preserving
      else
        :resize
      end

    {:effective, dpr_ratio(request), mode}
  end

  defp imgproxy_resize_dimension(nil), do: {:ok, :auto}
  defp imgproxy_resize_dimension(:auto), do: {:ok, :auto}
  defp imgproxy_resize_dimension({:pixels, 0}), do: {:ok, :auto}

  defp imgproxy_resize_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_resize_dimension({:scale, value}), do: tagged_ratio_from_decimal(value)

  defp imgproxy_tagged_crop_dimension(:auto), do: {:ok, :full_axis}
  defp imgproxy_tagged_crop_dimension({:pixels, 0}), do: {:ok, :full_axis}

  defp imgproxy_tagged_crop_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_tagged_crop_dimension({:scale, value}) do
    tagged_ratio_from_decimal(value)
  end

  defp imgproxy_canvas_dimension(nil), do: {:ok, :auto}
  defp imgproxy_canvas_dimension(:auto), do: {:ok, :auto}
  defp imgproxy_canvas_dimension({:pixels, 0}), do: {:ok, :auto}

  defp imgproxy_canvas_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp imgproxy_canvas_dimension({:scale, value}), do: tagged_ratio_from_decimal(value)

  defp optional_resize_dimension(nil), do: {:ok, nil}
  defp optional_resize_dimension({:pixels, 0}), do: {:ok, :auto}
  defp optional_resize_dimension(dimension), do: imgproxy_resize_dimension(dimension)

  defp resize_guide(:sm, true), do: {:ok, {:smart, :face_assist}}
  defp resize_guide(:sm, _face_assist), do: {:ok, :smart}
  defp resize_guide({:obj, classes}, _face_assist), do: {:ok, object_detect_guide(classes)}

  defp resize_guide({:objw, pairs}, _face_assist), do: {:ok, objw_guide(pairs)}

  defp resize_guide({:anchor, :center, :center}, _face_assist), do: {:ok, :center}
  defp resize_guide({:anchor, x, y}, _face_assist), do: {:ok, {:anchor, x, y}}

  defp resize_guide({:fp, x, y}, _face_assist) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp tagged_gravity(:sm, true), do: {:ok, {:smart, :face_assist}}
  defp tagged_gravity(:sm, _face_assist), do: {:ok, :smart}
  defp tagged_gravity({:obj, classes}, _face_assist), do: {:ok, object_detect_guide(classes)}

  defp tagged_gravity({:objw, pairs}, _face_assist), do: {:ok, objw_guide(pairs)}

  defp tagged_gravity({:anchor, x, y}, _face_assist), do: {:ok, crop_anchor_guide(x, y)}

  defp tagged_gravity({:fp, x, y}, _face_assist) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp canvas_placement({:anchor, x, y}), do: {:ok, crop_anchor_guide(x, y)}

  defp canvas_placement({:fp, x, y}) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp tagged_ratio_from_decimal(value) do
    with {:ok, {numerator, denominator}} <- decimal_ratio_parts(value) do
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    end
  end

  # Derives the detect guide from an objw pairs list. The named classes form the
  # detection spec (exactly like obj); `all` broadens spec to :all and maps to
  # :default in the weight map. Shared by resize_guide (fill) and tagged_gravity
  # (crop) so the paths cannot diverge.
  defp objw_guide(pairs) do
    classes = pairs |> Enum.map(fn {class, _weight} -> class end) |> Enum.uniq()
    object_detect_guide(classes, canonical_weights(pairs))
  end

  # Maps imgproxy object gravity to a product-neutral detect guide. Bare `obj`
  # (empty classes) or `all` anywhere collapses spec to :all; otherwise the class
  # list is carried through. Weights are empty for `obj`; `objw` supplies a
  # canonical map via the /2 form. Shared by resize_guide (fill) and
  # tagged_gravity (crop) so the paths cannot diverge.
  defp object_detect_guide(classes), do: object_detect_guide(classes, %{})

  defp object_detect_guide(classes, weights) when is_map(weights) do
    spec = if classes == [] or "all" in classes, do: :all, else: classes
    {:detect, {spec, weights}}
  end

  # Canonicalizes raw objw pairs into the sparse plan weights map. `all` →
  # :default; later pairs win on duplicate keys. Then the fixed-point drop rules
  # (effective default = :default or 1.0): drop class entries equal to it, then
  # drop :default when it is 1.0. The only place objw weights are canonicalized.
  defp canonical_weights(pairs) do
    raw =
      Enum.reduce(pairs, %{}, fn {class, weight}, acc ->
        key = if class == "all", do: :default, else: class
        Map.put(acc, key, weight)
      end)

    eff = Map.get(raw, :default, 1.0)

    raw
    |> Enum.reject(fn {key, weight} -> key != :default and weight == eff end)
    |> Map.new()
    |> drop_default_one()
  end

  defp drop_default_one(%{default: 1.0} = weights), do: Map.delete(weights, :default)
  defp drop_default_one(weights), do: weights

  defp crop_anchor_guide(:center, :center), do: :center
  defp crop_anchor_guide(:left, :top), do: :top_left
  defp crop_anchor_guide(:center, :top), do: :top
  defp crop_anchor_guide(:right, :top), do: :top_right
  defp crop_anchor_guide(:left, :center), do: :left
  defp crop_anchor_guide(:right, :center), do: :right
  defp crop_anchor_guide(:left, :bottom), do: :bottom_left
  defp crop_anchor_guide(:center, :bottom), do: :bottom
  defp crop_anchor_guide(:right, :bottom), do: :bottom_right

  defp default_monochrome_color, do: color!(179, 179, 179)
  defp default_duotone_shadow, do: color!(0, 0, 0)
  defp default_duotone_highlight, do: color!(255, 255, 255)
  defp default_colorize_color, do: color!(0, 0, 0)

  defp color!(red, green, blue) do
    {:ok, color} = Operation.color(red, green, blue)
    color
  end

  defp enlargement(%PipelineRequest{resizing_type: :fill_down}), do: :deny
  defp enlargement(%PipelineRequest{enlarge: true}), do: :allow
  defp enlargement(%PipelineRequest{}), do: :deny

  # Parser values are already floats for decimal syntax. Preserve the decimal
  # spelling Elixir prints for compatibility, instead of materializing the raw
  # IEEE-754 fraction.
  defp decimal_ratio_parts(value) when is_integer(value) and value >= 0, do: {:ok, {value, 1}}

  defp decimal_ratio_parts(value) when is_float(value) and value >= 0.0 do
    value
    |> :erlang.float_to_binary([:compact, decimals: 12])
    |> decimal_string_ratio()
  end

  defp decimal_string_ratio(value) do
    case String.split(value, ".") do
      [integer] ->
        {numerator, ""} = Integer.parse(integer)
        {:ok, {numerator, 1}}

      [integer, fraction_text] ->
        {integer, ""} = Integer.parse(integer)
        {fraction, ""} = Integer.parse(fraction_text)
        denominator = integer_power(10, String.length(fraction_text))
        {:ok, {integer * denominator + fraction, denominator}}
    end
  end

  defp integer_power(base, exponent) do
    Enum.reduce(1..exponent//1, 1, fn _index, product -> product * base end)
  end

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}
end
