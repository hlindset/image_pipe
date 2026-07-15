defmodule ImagePipe.Dialect.Imgproxy.Assembly do
  @moduledoc false

  # Semantic operation assembly for the imgproxy dialect: turns one
  # `PipelineRequest` into the `Plan.Operation` list its pipeline runs, and
  # derives the padding/canvas mode that list implies.
  #
  # A phase-1 copy of the frozen `ImagePipe.Parser.Imgproxy.PlanBuilder`'s
  # geometry half — the inverted dialect owns its whole request chain and may
  # not depend on the Parser boundary, while both arms run side by side. Split
  # out of `ImagePipe.Dialect.Imgproxy.Pipeline` so the port lives apart from
  # the resolve-loop driver and the carry math it feeds, mirroring the split
  # the framework already has between `PlanBuilder` and `Executor`/`Resolver`.
  #
  # `operations/1` is a COMPLETE port of `plan_geometry/1` (`plan_builder.ex:
  # 254-290`) and every private helper it reaches: the five `missing_dimensions/1`
  # guard clauses, then all eight stages (trim -> orientation -> crop -> resize
  # -> effects -> canvas -> padding -> background). Ported clause-for-clause,
  # including the parts that look redundant — clause ORDER is load-bearing in
  # three places, each marked below. `pipeline_ctx/1` ports
  # `effective_padding_pixel_ratio/1`'s mode half (`plan_builder.ex:677-686`).
  #
  # ONE deliberate divergence [spec D5]: padding is emitted with a concrete
  # `pixel_ratio: dpr_ratio(preq)` instead of the framework's `{:effective,
  # fallback, mode}` marker — the dialect owns both emit and run, so the mode
  # lives in `pipeline_ctx/1` and the marker is never constructed. The
  # correspondence between the two spellings is pinned by
  # `pipeline_assembly_test.exs`, which compares both arms row for row.
  #
  # Three deliberate narrowings, not gaps — the request grammar cannot produce
  # the dropped inputs, so porting them would add unreachable surface:
  #   * `resize_dimension/1`/`canvas_dimension/1` omit plan_builder's
  #     `{:scale, _}` and `:auto` clauses: `PipelineRequest`'s width/height/min_*
  #     are `ImagePipe.imgp_pixels() | nil`, i.e. `{:pixels, non_neg_integer()}`.
  #     `crop_dimension/1` keeps both — `CropRequest.dimension()` is `:auto |
  #     {:scale, number()} | imgp_pixels()`, and `:auto` is its own default.
  #   * `canvas_placement/1` omits plan_builder's `{:fp, _, _}` clause: the
  #     grammar parses extend gravity with `parse_gravity_anchor/1` only, so
  #     `extend_gravity`/`extend_aspect_ratio_gravity` are anchors or nil.
  #     `tagged_gravity/2` (crop) keeps every clause — a crop's gravity, and the
  #     top-level gravity a bare crop inherits, span the full `gravity()` type.

  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Effects
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Dialect.Imgproxy.PipelineRequest
  alias ImagePipe.Plan.Operation

  @default_gravity {:anchor, :center, :center}

  @typedoc """
  A geometry rejection. `:missing_dimensions` is this module's own — the rest
  come from the `Plan.Operation` constructors it calls.
  """
  @type error() ::
          {:missing_dimensions, PipelineRequest.resizing_type()} | Operation.error()

  @doc """
  The `Plan.Operation` list one imgproxy pipeline runs, in plan_builder's fixed
  stage order, or the request-level rejection its geometry implies.

  The error tuples are byte-identical to the framework arm's, which raises them
  from `PlanBuilder.to_plan/2` at PARSE time — before any source fetch. The
  dialect reaches this code at run time instead, so a rejected request is
  currently rejected after its source is fetched and decoded: the dialect's
  Plug chain should call `operations/1` before the fetch to restore that
  ordering.
  """
  @spec operations(PipelineRequest.t()) ::
          {:ok, [Operation.semantic_operation()]} | {:error, error()}
  def operations(request)

  # Ports `plan_geometry/1`'s five guard clauses (`plan_builder.ex:254-269`)
  # verbatim, ORDER included: they precede every stage, so a request rejected
  # here never reaches the trim/orientation/crop assembly below. `{:pixels, 0}`
  # is "auto", not "unset" — these key off `nil` only.
  def operations(%PipelineRequest{resizing_type: :fill, width: nil, height: nil}),
    do: missing_dimensions(:fill)

  def operations(%PipelineRequest{resizing_type: :fill, width: nil}),
    do: missing_dimensions(:fill)

  def operations(%PipelineRequest{resizing_type: :fill, height: nil}),
    do: missing_dimensions(:fill)

  def operations(%PipelineRequest{resizing_type: resizing_type, width: nil})
      when resizing_type in [:fill_down, :auto],
      do: missing_dimensions(resizing_type)

  def operations(%PipelineRequest{resizing_type: resizing_type, height: nil})
      when resizing_type in [:fill_down, :auto],
      do: missing_dimensions(resizing_type)

  def operations(%PipelineRequest{} = request) do
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

  defp missing_dimensions(resizing_type), do: {:error, {:missing_dimensions, resizing_type}}

  @doc """
  The padding/canvas decision context `operations/1`'s list implies.

  The padding/canvas mode is parse-time-decidable request data [spec D5]:
  nothing here consults runtime geometry, which is exactly why the framework's
  `{:effective, fallback, mode}` marker is pure redundancy once one module owns
  both emit and run. Ports `plan_builder.ex:677-686` and the whole predicate
  closure it reaches — including `resize_target_ratio/1`, which reads
  width/height rather than any `extend*` field.
  """
  @spec pipeline_ctx(PipelineRequest.t()) :: %{
          mode: :resize | :canvas_preserving,
          dpr_fallback: float()
        }
  def pipeline_ctx(%PipelineRequest{} = request) do
    mode =
      if extend_operation_requested?(request) or extend_aspect_ratio_emits?(request),
        do: :canvas_preserving,
        else: :resize

    %{mode: mode, dpr_fallback: request.dpr || 1.0}
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

  # ── stage 1: trim ────────────────────────────────────────────────────────

  defp trim_operations(%PipelineRequest{trim: nil}), do: {:ok, []}

  defp trim_operations(%PipelineRequest{trim: trim}) do
    with {:ok, operation} <- Operation.trim(trim) do
      {:ok, [operation]}
    end
  end

  # ── stage 2: orientation ─────────────────────────────────────────────────
  #
  # `auto_orient` is not an operation: EXIF auto-orient is deferred
  # `pending_orientation` state the flush boundary applies, never a Plan op.

  defp orientation_operations(%PipelineRequest{orientation: %Orientation{} = orientation}) do
    [
      rotate_operation(orientation),
      flip_operation(orientation)
    ]
    |> Enum.reject(&is_nil/1)
    |> reduce_results()
  end

  defp rotate_operation(%Orientation{rotate: 0}), do: nil

  defp rotate_operation(%Orientation{rotate: angle}) when angle in [90, 180, 270],
    do: Operation.rotate(angle)

  defp flip_operation(%Orientation{flip: nil}), do: nil

  defp flip_operation(%Orientation{flip: axis}) when axis in [:horizontal, :vertical, :both],
    do: Operation.flip(axis)

  # ── stage 3: crop ────────────────────────────────────────────────────────

  defp crop_operations(%PipelineRequest{crop: nil}), do: {:ok, []}

  defp crop_operations(%PipelineRequest{crop: %CropRequest{} = crop} = request) do
    {gravity, x_offset, y_offset} = crop_gravity(crop, request)

    with {:ok, width} <- crop_dimension(crop.width),
         {:ok, height} <- crop_dimension(crop.height),
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

  # ── stage 4: resize ──────────────────────────────────────────────────────
  #
  # Ports `plan_builder.ex:363-388`'s `resize_operations/1` clause-for-clause.
  # Two ordering facts, both load-bearing:
  #
  #   * The two dimensionless clauses sit BEFORE the `resizing_type: :auto`
  #     clause, so a ruleless `rt:auto/w:0/h:0` emits nothing. Promoting the
  #     `:auto` clause — the more specific match, a tempting reorder — would
  #     route it to `resize_operation/1` and emit a resize the framework does
  #     not.
  #   * The fit/fill/fill_down/force clause goes through `resize_from_rule/1`,
  #     which MAPS the dimensions before `resize_operations_for/3`'s
  #     `{:auto, :auto, false}` guard can see them. A catch-all that skips the
  #     mapping can never reach that guard, and emits where the framework
  #     emits nothing.
  #
  # The `:auto` clause's own route to `resize_operation/1` skips that guard, but
  # unobservably: reaching `{:auto, :auto}` needs both dimensions nil or both
  # `{:pixels, 0}`, and for `:auto` the former is rejected by the
  # `missing_dimensions/1` guards above and the latter is claimed by the second
  # clause here. Ported as written regardless — the frozen arm's shape is the
  # contract, not our reachability analysis of it.

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

  # Maps the dimensions BEFORE the guard sees them — that mapping is the whole
  # point: `w:0` with no height is `{:pixels, 0}`/`nil`, which only resolves to
  # `{:auto, :auto}` after `resize_dimension/1` has run.
  defp resize_from_rule(%PipelineRequest{} = request) do
    with {:ok, width} <- resize_dimension(request.width),
         {:ok, height} <- resize_dimension(request.height) do
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

  # Ports `plan_builder.ex:627-661`'s FULL opt list. Every one of these fields is
  # read back by the carry math: `padding_scale/4` runs the emitted op through
  # `ResizePlanning.resize_from/2` + `Resize.resolve_dimensions/2`, so an opt
  # dropped here silently changes the padding scale. A dropped `zoom_*` is the
  # sharpest case — it leaves `requested_*` at `:auto` and routes a zoomed
  # request into the auto/auto clause of `max_padding_scale_without_enlarge/2`
  # that that clause's own comment says it can never reach.
  defp resize_operation(%PipelineRequest{} = request) do
    with {:ok, width} <- resize_dimension(request.width),
         {:ok, height} <- resize_dimension(request.height),
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

  # `plan_builder.ex:830-832`. The `:fill_down` clause comes FIRST and overrides
  # `enlarge: true` — imgproxy's fill-down never enlarges, whatever `el` says.
  defp enlargement(%PipelineRequest{resizing_type: :fill_down}), do: :deny
  defp enlargement(%PipelineRequest{enlarge: true}), do: :allow
  defp enlargement(%PipelineRequest{}), do: :deny

  defp resize_mode(:fit), do: :fit
  defp resize_mode(:fill), do: :cover
  defp resize_mode(:fill_down), do: :cover
  defp resize_mode(:force), do: :stretch
  defp resize_mode(:auto), do: :auto

  # ── stage 5: effects ─────────────────────────────────────────────────────
  #
  # Each per-effect identity point (`blur=0`, `pixelate<=1`, `contrast=1.0`, a
  # zero intensity/opacity ratio, …) is its own guard clause; each suppresses an
  # operation the framework arm would not emit.

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

  defp default_monochrome_color, do: color!(179, 179, 179)
  defp default_duotone_shadow, do: color!(0, 0, 0)
  defp default_duotone_highlight, do: color!(255, 255, 255)
  defp default_colorize_color, do: color!(0, 0, 0)

  defp color!(red, green, blue) do
    {:ok, color} = Operation.color(red, green, blue)
    color
  end

  # ── stage 6: canvas ──────────────────────────────────────────────────────
  #
  # Ports `plan_builder.ex:417-475`'s `canvas_operations/1` — BOTH canvases, in
  # order. `pipeline_ctx/1` already flips the pipeline to `:canvas_preserving`
  # when either would emit, so omitting one would leave the mode answering for an
  # operation that never runs.

  defp canvas_operations(%PipelineRequest{} = request) do
    [
      extend_operation(request),
      extend_aspect_ratio_operation(request)
    ]
    |> Enum.reject(&is_nil/1)
    |> reduce_results()
  end

  defp extend_operation(%PipelineRequest{} = request) do
    if extend_operation_requested?(request) do
      with {:ok, width} <- canvas_dimension(request.width),
           {:ok, height} <- canvas_dimension(request.height),
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

  # The aspect-ratio canvas box is `{:ratio, w, 1}` x `{:ratio, h, 1}`, which
  # `Lowering.canvas_executables/2` reads as an `{:aspect_ratio, {w, h}}` rule and
  # deliberately leaves unscaled — it is computed from the already-dpr-scaled
  # image. `resize_target_ratio/1` is the same predicate `pipeline_ctx/1` uses, so
  # the mode and the emission cannot disagree.
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

  # ── stage 7: padding ─────────────────────────────────────────────────────

  # The `{:effective, fallback, mode}` marker is NEVER constructed [spec D5]:
  # the dialect owns both emit and run, so the mode lives in `pipeline_ctx/1`
  # and the scale is handed to `Lowering.padding_executables/2` as an argument.
  # `pixel_ratio` is inert here — `padding_executables/2` reads only the sides
  # and the fill — but it is emitted as the request's own concrete ratio rather
  # than left to default, so the Plan op still describes the request truthfully.
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
             pixel_ratio: dpr_ratio(request),
             fill: :transparent
           ) do
      {:ok, [operation]}
    end
  end

  defp dpr_ratio(%PipelineRequest{dpr: nil}), do: {:ratio, 1, 1}

  defp dpr_ratio(%PipelineRequest{dpr: dpr}) do
    case Operation.resize(:fit, :auto, :auto, dpr: dpr) do
      {:ok, %{dpr: ratio}} -> ratio
    end
  end

  # ── stage 8: background ──────────────────────────────────────────────────

  defp background_operations(%PipelineRequest{background_color: nil}), do: {:ok, []}

  defp background_operations(%PipelineRequest{background_color: color}) do
    with {:ok, operation} <- Operation.background(color) do
      {:ok, [operation]}
    end
  end

  # ── dimensions ───────────────────────────────────────────────────────────

  defp resize_dimension(nil), do: {:ok, :auto}
  defp resize_dimension({:pixels, 0}), do: {:ok, :auto}

  defp resize_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp crop_dimension(:auto), do: {:ok, :full_axis}
  defp crop_dimension({:pixels, 0}), do: {:ok, :full_axis}

  defp crop_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp crop_dimension({:scale, value}), do: tagged_ratio_from_decimal(value)

  defp canvas_dimension(nil), do: {:ok, :auto}
  defp canvas_dimension({:pixels, 0}), do: {:ok, :auto}

  defp canvas_dimension({:pixels, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  # `mw:0`/`mh:0` mean "no minimum on this axis" (`:auto`), NOT "unset" (`nil`) —
  # `plan_builder.ex:716-718`.
  defp optional_resize_dimension(nil), do: {:ok, nil}
  defp optional_resize_dimension({:pixels, 0}), do: {:ok, :auto}
  defp optional_resize_dimension(dimension), do: resize_dimension(dimension)

  # ── gravity ──────────────────────────────────────────────────────────────
  #
  # `resize_guide/2` (fill) and `tagged_gravity/2` (crop) differ on ONE clause and
  # agree on the rest: an anchor becomes `{:anchor, x, y}` for a resize but a
  # named atom for a crop. `object_detect_guide/1,2` and `objw_guide/1` are shared
  # between them so the paths cannot diverge (plan_builder's own comment).

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

  defp tagged_gravity({:anchor, x, y}, _face_assist), do: {:ok, anchor_guide(x, y)}

  defp tagged_gravity({:fp, x, y}, _face_assist) do
    with {:ok, x} <- tagged_ratio_from_decimal(x),
         {:ok, y} <- tagged_ratio_from_decimal(y) do
      {:ok, {:focal, x, y}}
    end
  end

  defp canvas_placement({:anchor, x, y}), do: {:ok, anchor_guide(x, y)}

  # Derives the detect guide from an objw pairs list. The named classes form the
  # detection spec (exactly like obj); `all` broadens spec to :all and maps to
  # :default in the weight map.
  defp objw_guide(pairs) do
    classes = pairs |> Enum.map(fn {class, _weight} -> class end) |> Enum.uniq()
    object_detect_guide(classes, canonical_weights(pairs))
  end

  # Maps imgproxy object gravity to a product-neutral detect guide. Bare `obj`
  # (empty classes) or `all` anywhere collapses spec to :all; otherwise the class
  # list is carried through. Weights are empty for `obj`; `objw` supplies a
  # canonical map via the /2 form.
  defp object_detect_guide(classes), do: object_detect_guide(classes, %{})

  defp object_detect_guide(classes, weights) when is_map(weights) do
    spec = if classes == [] or "all" in classes, do: :all, else: classes
    {:detect, {spec, weights}}
  end

  # Canonicalizes raw objw pairs into the sparse plan weights map. `all` ->
  # :default; later pairs win on duplicate keys. Then the fixed-point drop rules
  # (effective default = :default or 1.0): drop class entries equal to it, then
  # drop :default when it is 1.0.
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

  defp anchor_guide(:center, :center), do: :center
  defp anchor_guide(:left, :top), do: :top_left
  defp anchor_guide(:center, :top), do: :top
  defp anchor_guide(:right, :top), do: :top_right
  defp anchor_guide(:left, :center), do: :left
  defp anchor_guide(:right, :center), do: :right
  defp anchor_guide(:left, :bottom), do: :bottom_left
  defp anchor_guide(:center, :bottom), do: :bottom
  defp anchor_guide(:right, :bottom), do: :bottom_right

  # ── decimal ratios ───────────────────────────────────────────────────────

  defp tagged_ratio_from_decimal(value) do
    with {:ok, {numerator, denominator}} <- decimal_ratio_parts(value) do
      gcd = Integer.gcd(numerator, denominator)
      {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
    end
  end

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
end
