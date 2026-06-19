defmodule ImagePipe.Plan.Operation do
  @moduledoc """
  Constructor facade for canonical semantic Plan operations.
  """

  alias ImagePipe.Plan.Color
  alias ImagePipe.Plan.Measure
  alias ImagePipe.Plan.Operation.Background
  alias ImagePipe.Plan.Operation.Bitonal
  alias ImagePipe.Plan.Operation.Blur
  alias ImagePipe.Plan.Operation.Brightness
  alias ImagePipe.Plan.Operation.Canvas
  alias ImagePipe.Plan.Operation.Colorize
  alias ImagePipe.Plan.Operation.Contrast
  alias ImagePipe.Plan.Operation.CropGuided
  alias ImagePipe.Plan.Operation.CropRegion
  alias ImagePipe.Plan.Operation.Duotone
  alias ImagePipe.Plan.Operation.Flip
  alias ImagePipe.Plan.Operation.Gray
  alias ImagePipe.Plan.Operation.Monochrome
  alias ImagePipe.Plan.Operation.Padding
  alias ImagePipe.Plan.Operation.Pixelate
  alias ImagePipe.Plan.Operation.Resize
  alias ImagePipe.Plan.Operation.Rotate
  alias ImagePipe.Plan.Operation.Saturation
  alias ImagePipe.Plan.Operation.SetFocus
  alias ImagePipe.Plan.Operation.Sharpen
  alias ImagePipe.Plan.Operation.Trim

  @enlargements [:allow, :deny, :reject]
  @flip_axes [:horizontal, :vertical, :both]
  @x_anchors [:left, :center, :right]
  @y_anchors [:top, :center, :bottom]
  @crop_anchor_guides [
    :center,
    :top_left,
    :top,
    :top_right,
    :left,
    :right,
    :bottom_left,
    :bottom,
    :bottom_right
  ]
  @resize_modes [:fit, :cover, :stretch, :auto]
  @semantic_resize_keys [
    :dpr,
    :down,
    :enlargement,
    :guide,
    :x_offset,
    :y_offset,
    :min_width,
    :min_height,
    :zoom_x,
    :zoom_y,
    :max_width,
    :max_height,
    :max_area
  ]
  @crop_guided_keys [:x_offset, :y_offset, :aspect_ratio, :enlarge]
  @canvas_keys [:fill, :overflow, :x_offset, :y_offset]
  @padding_keys [:pixel_ratio, :fill]
  @trim_keys [:threshold, :background, :equal_hor, :equal_ver]
  @effective_padding_modes [:resize, :canvas_preserving]
  @brightness_range -255..255
  @type resize_operation :: Resize.t()

  @type crop_operation ::
          CropGuided.t()
          | CropRegion.t()

  @type canvas_operation :: Canvas.t()

  @type padding_operation :: Padding.t()

  @type background_operation :: Background.t()

  @type orientation_operation ::
          Rotate.t()
          | Flip.t()

  @type focus_operation :: SetFocus.t()

  @type effect_operation ::
          Bitonal.t()
          | Blur.t()
          | Sharpen.t()
          | Pixelate.t()
          | Monochrome.t()
          | Duotone.t()
          | Colorize.t()
          | Brightness.t()
          | Contrast.t()
          | Saturation.t()

  @type trim_operation :: Trim.t()

  @type semantic_operation ::
          resize_operation()
          | crop_operation()
          | canvas_operation()
          | padding_operation()
          | background_operation()
          | orientation_operation()
          | focus_operation()
          | effect_operation()
          | trim_operation()

  @type error ::
          {:invalid_operation, atom(), term()} | {:unknown_operation_options, atom(), [atom()]}

  @spec rotate(term(), term()) :: {:ok, Rotate.t()} | {:error, error()}
  def rotate(angle, mirror \\ false)

  def rotate(angle, mirror) when is_number(angle) and is_boolean(mirror) do
    case normalize_rotation_angle(angle) do
      {:ok, normalized} -> {:ok, %Rotate{angle: normalized, mirror: mirror}}
      :error -> invalid(:rotate, [angle, mirror])
    end
  end

  def rotate(angle, mirror), do: invalid(:rotate, [angle, mirror])

  # Accept the closed interval [0, 360]; fold 360 -> 0 and whole floats -> ints so
  # right angles route to the lossless rotate path.
  defp normalize_rotation_angle(angle) when angle >= 0 and angle <= 360 do
    reduced = if angle == 360, do: 0, else: angle
    {:ok, whole_to_integer(reduced)}
  end

  defp normalize_rotation_angle(_angle), do: :error

  defp whole_to_integer(value) when is_float(value) do
    truncated = trunc(value)
    if value == truncated, do: truncated, else: value
  end

  defp whole_to_integer(value), do: value

  @spec flip(term()) :: {:ok, Flip.t()} | {:error, error()}
  def flip(axis) when axis in @flip_axes, do: {:ok, %Flip{axis: axis}}
  def flip(axis), do: invalid(:flip, [axis])

  @spec blur(term()) :: {:ok, Blur.t()} | {:error, error()}
  def blur(sigma) when is_number(sigma) and sigma > 0,
    do: {:ok, %Blur{sigma: sigma * 1.0}}

  def blur(sigma), do: invalid(:blur, [sigma])

  @spec sharpen(term()) :: {:ok, Sharpen.t()} | {:error, error()}
  def sharpen(sigma) when is_number(sigma) and sigma > 0,
    do: {:ok, %Sharpen{sigma: sigma * 1.0}}

  def sharpen(sigma), do: invalid(:sharpen, [sigma])

  @spec pixelate(term()) :: {:ok, Pixelate.t()} | {:error, error()}
  def pixelate(size) when is_integer(size) and size > 1, do: {:ok, %Pixelate{size: size}}
  def pixelate(size), do: invalid(:pixelate, [size])

  @spec monochrome(term(), term()) :: {:ok, Monochrome.t()} | {:error, error()}
  def monochrome(intensity, %Color{} = color) do
    with {:ok, intensity} <- effect_intensity(intensity),
         true <- Color.valid?(color) do
      {:ok, %Monochrome{intensity: intensity, color: color}}
    else
      _reason -> invalid(:monochrome, [intensity, color])
    end
  end

  def monochrome(intensity, color), do: invalid(:monochrome, [intensity, color])

  @spec duotone(term(), term(), term()) :: {:ok, Duotone.t()} | {:error, error()}
  def duotone(intensity, %Color{} = shadow, %Color{} = highlight) do
    with {:ok, intensity} <- effect_intensity(intensity),
         true <- Color.valid?(shadow),
         true <- Color.valid?(highlight) do
      {:ok, %Duotone{intensity: intensity, shadow: shadow, highlight: highlight}}
    else
      _reason -> invalid(:duotone, [intensity, shadow, highlight])
    end
  end

  def duotone(intensity, shadow, highlight),
    do: invalid(:duotone, [intensity, shadow, highlight])

  @spec colorize(term(), term(), term()) :: {:ok, Colorize.t()} | {:error, error()}
  def colorize(opacity, %Color{} = color, keep_alpha) when is_boolean(keep_alpha) do
    with {:ok, opacity} <- effect_intensity(opacity),
         true <- Color.valid?(color) do
      {:ok, %Colorize{opacity: opacity, color: color, keep_alpha: keep_alpha}}
    else
      _reason -> invalid(:colorize, [opacity, color, keep_alpha])
    end
  end

  def colorize(opacity, color, keep_alpha), do: invalid(:colorize, [opacity, color, keep_alpha])

  @spec brightness(term()) :: {:ok, Brightness.t()} | {:error, error()}
  def brightness(value) when is_integer(value) and value in @brightness_range,
    do: {:ok, %Brightness{value: value}}

  def brightness(value), do: invalid(:brightness, [value])

  @spec contrast(term()) :: {:ok, Contrast.t()} | {:error, error()}
  def contrast(value) when is_number(value) and value > 0,
    do: {:ok, %Contrast{value: value * 1.0}}

  def contrast(value), do: invalid(:contrast, [value])

  @spec saturation(term()) :: {:ok, Saturation.t()} | {:error, error()}
  def saturation(value) when is_number(value) and value > 0,
    do: {:ok, %Saturation{value: value * 1.0}}

  def saturation(value), do: invalid(:saturation, [value])

  @spec color(term(), term(), term()) :: {:ok, Color.t()} | {:error, term()}
  def color(red, green, blue), do: Color.rgb(red, green, blue)

  @spec color(term(), term(), term(), term()) :: {:ok, Color.t()} | {:error, term()}
  def color(red, green, blue, alpha), do: Color.rgba(red, green, blue, alpha)

  @spec crop_guided(term(), term(), term(), keyword()) ::
          {:ok, CropGuided.t()} | {:error, error()}
  def crop_guided(width, height, guide, opts \\ [])

  def crop_guided(width, height, guide, opts) when is_list(opts) do
    with :ok <- validate_known_options(:crop_guided, opts, @crop_guided_keys),
         {:ok, width} <- tagged_crop_dimension(width),
         {:ok, height} <- tagged_crop_dimension(height),
         {:ok, guide} <- tagged_crop_guide(guide),
         {:ok, x_offset} <- offset(opts, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(opts, :y_offset, {:pixels, 0.0}),
         {:ok, aspect_ratio} <- crop_aspect_ratio_option(Keyword.get(opts, :aspect_ratio)),
         {:ok, enlarge} <- crop_enlarge_option(Keyword.get(opts, :enlarge, false)) do
      {:ok,
       %CropGuided{
         width: width,
         height: height,
         guide: guide,
         x_offset: x_offset,
         y_offset: y_offset,
         aspect_ratio: aspect_ratio,
         enlarge: enlarge
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:crop_guided, [width, height, guide, opts])
    end
  end

  @spec crop_region(term(), term(), term(), term()) :: {:ok, CropRegion.t()} | {:error, error()}
  def crop_region(x, y, width, height) do
    with {:ok, x} <- tagged_crop_coordinate(x),
         {:ok, y} <- tagged_crop_coordinate(y),
         {:ok, width} <- tagged_crop_region_dimension(width),
         {:ok, height} <- tagged_crop_region_dimension(height) do
      {:ok, %CropRegion{x: x, y: y, width: width, height: height}}
    else
      {:error, _reason} -> invalid(:crop_region, [x, y, width, height])
    end
  end

  @spec set_focus(term()) :: {:ok, SetFocus.t()} | {:error, error()}
  def set_focus({:coord, x, y}) do
    with {:ok, x} <- Measure.position(x),
         {:ok, y} <- Measure.position(y) do
      {:ok, %SetFocus{point: {:coord, x, y}}}
    else
      _ -> invalid(:set_focus, [{:coord, x, y}])
    end
  end

  def set_focus({:anchor, h, v}) when h in @x_anchors and v in @y_anchors,
    do: {:ok, %SetFocus{point: {:anchor, h, v}}}

  def set_focus(other), do: invalid(:set_focus, [other])

  @spec canvas(term(), term(), term(), keyword()) :: {:ok, Canvas.t()} | {:error, error()}
  def canvas(width, height, placement, opts \\ [])

  def canvas(width, height, placement, opts) when is_list(opts) do
    with :ok <- validate_known_options(:canvas, opts, @canvas_keys),
         {:ok, width} <- tagged_canvas_dimension(width),
         {:ok, height} <- tagged_canvas_dimension(height),
         {:ok, placement} <- tagged_canvas_placement(placement),
         :ok <- validate_canvas_dimension_pair(width, height, :canvas),
         {:ok, fill} <- optional_fill(opts, :fill, :transparent),
         {:ok, :reject} <- optional_exact(opts, :overflow, :reject),
         {:ok, x_offset} <- signed_numeric(opts, :x_offset, 0.0),
         {:ok, y_offset} <- signed_numeric(opts, :y_offset, 0.0) do
      {:ok,
       %Canvas{
         width: width,
         height: height,
         placement: placement,
         fill: fill,
         overflow: :reject,
         x_offset: x_offset,
         y_offset: y_offset
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:canvas, [width, height, placement, opts])
    end
  end

  @spec padding(term(), term(), term(), term(), keyword()) ::
          {:ok, Padding.t()} | {:error, error()}
  def padding(top, right, bottom, left, opts \\ [])

  def padding(top, right, bottom, left, opts) when is_list(opts) do
    with :ok <- validate_known_options(:padding, opts, @padding_keys),
         {:ok, top} <- tagged_padding_side(top),
         {:ok, right} <- tagged_padding_side(right),
         {:ok, bottom} <- tagged_padding_side(bottom),
         {:ok, left} <- tagged_padding_side(left),
         :ok <- validate_positive_padding([top, right, bottom, left]),
         {:ok, pixel_ratio} <-
           opts
           |> Keyword.get(:pixel_ratio, {:ratio, 1, 1})
           |> tagged_padding_pixel_ratio(),
         {:ok, fill} <- optional_fill(opts, :fill, :transparent) do
      {:ok,
       %Padding{
         top: top,
         right: right,
         bottom: bottom,
         left: left,
         pixel_ratio: pixel_ratio,
         fill: fill
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:padding, [top, right, bottom, left, opts])
    end
  end

  @spec background(term()) :: {:ok, Background.t()} | {:error, error()}
  def background(%Color{} = color) do
    case Color.valid?(color) do
      true -> {:ok, %Background{color: color}}
      false -> invalid(:background, [color])
    end
  end

  def background(color), do: invalid(:background, [color])

  @spec trim(keyword()) :: {:ok, Trim.t()} | {:error, error()}
  def trim(opts) when is_list(opts) do
    with :ok <- validate_known_options(:trim, opts, @trim_keys),
         {:ok, threshold} <- trim_threshold(Keyword.get(opts, :threshold)),
         {:ok, background} <- trim_background(Keyword.get(opts, :background, :auto)),
         {:ok, equal_hor} <- trim_flag(Keyword.get(opts, :equal_hor, false)),
         {:ok, equal_ver} <- trim_flag(Keyword.get(opts, :equal_ver, false)) do
      {:ok,
       %Trim{
         threshold: threshold,
         background: background,
         equal_hor: equal_hor,
         equal_ver: equal_ver
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:trim, [opts])
    end
  end

  defp trim_threshold(value) when is_number(value), do: {:ok, value * 1.0}
  defp trim_threshold(value), do: {:error, {:invalid_trim_threshold, value}}

  defp trim_background(:auto), do: {:ok, :auto}

  defp trim_background(%Color{} = color) do
    case Color.valid?(color) do
      true -> {:ok, color}
      false -> {:error, {:invalid_trim_background, color}}
    end
  end

  defp trim_background(value), do: {:error, {:invalid_trim_background, value}}

  defp trim_flag(value) when is_boolean(value), do: {:ok, value}
  defp trim_flag(value), do: {:error, {:invalid_trim_flag, value}}

  @spec resize(Resize.mode(), term(), term(), keyword()) ::
          {:ok, Resize.t()} | {:error, error()}
  def resize(mode, width, height, opts \\ [])

  def resize(mode, width, height, opts) when is_list(opts) do
    with :ok <- validate_known_options(:resize, opts, @semantic_resize_keys),
         {:ok, mode} <- resize_mode(mode),
         {:ok, width} <- tagged_resize_dimension(width),
         {:ok, height} <- tagged_resize_dimension(height),
         {:ok, dpr} <- resize_dpr(Keyword.get(opts, :dpr, 1)),
         {:ok, enlargement} <-
           optional_member(opts, :enlargement, @enlargements, :deny),
         {:ok, down} <- resize_down(opts),
         {:ok, guide} <- resize_guide(Keyword.get(opts, :guide, :center)),
         {:ok, x_offset} <- offset(opts, :x_offset, {:pixels, 0.0}),
         {:ok, y_offset} <- offset(opts, :y_offset, {:pixels, 0.0}),
         {:ok, {x_offset, y_offset}} <- resize_offsets(mode, x_offset, y_offset),
         {:ok, min_width} <- optional_tagged_resize_dimension(opts, :min_width),
         {:ok, min_height} <- optional_tagged_resize_dimension(opts, :min_height),
         {:ok, zoom_x} <- numeric(opts, :zoom_x, 1.0),
         {:ok, zoom_y} <- numeric(opts, :zoom_y, 1.0),
         {:ok, max_width} <- optional_positive_integer(opts, :max_width),
         {:ok, max_height} <- optional_positive_integer(opts, :max_height),
         {:ok, max_area} <- optional_positive_integer(opts, :max_area) do
      {:ok,
       %Resize{
         mode: mode,
         width: width,
         height: height,
         dpr: dpr,
         down: down,
         enlargement: enlargement,
         guide: guide,
         x_offset: x_offset,
         y_offset: y_offset,
         min_width: min_width,
         min_height: min_height,
         zoom_x: zoom_x,
         zoom_y: zoom_y,
         max_width: max_width,
         max_height: max_height,
         max_area: max_area
       }}
    else
      {:error, {:unknown_operation_options, _operation, _keys} = reason} ->
        {:error, reason}

      {:error, _reason} ->
        invalid(:resize, [mode, width, height, opts])
    end
  end

  @doc """
  Stable, product-neutral name atom for a semantic operation struct
  (e.g. `%Operation.Resize{}` -> `:resize`). Derived from the struct module's
  tail; used for telemetry metadata. Bounded by defined operation modules.
  Every operation name also appears as a literal in a compiled module (a
  constructor here, a key-data table, or the operation's transform module), so
  the atom is always pre-loaded and `String.to_existing_atom/1` cannot raise for
  an in-repo operation.
  """
  @spec name(struct()) :: atom()
  def name(%mod{}) do
    mod
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_existing_atom()
  end

  @spec semantic?(term()) :: boolean()
  def semantic?(%Resize{} = operation), do: valid_resize?(operation)
  def semantic?(%CropGuided{} = operation), do: valid_crop_guided?(operation)
  def semantic?(%CropRegion{} = operation), do: valid_crop_region?(operation)
  def semantic?(%Canvas{} = operation), do: valid_canvas?(operation)
  def semantic?(%Padding{} = operation), do: valid_padding?(operation)
  def semantic?(%Background{} = operation), do: valid_background?(operation)

  def semantic?(%Rotate{angle: angle, mirror: mirror}),
    do: is_number(angle) and angle >= 0 and angle < 360 and is_boolean(mirror)

  def semantic?(%Flip{axis: axis}) when axis in @flip_axes, do: true
  def semantic?(%Blur{} = operation), do: valid_positive_float?(operation.sigma)
  def semantic?(%Sharpen{} = operation), do: valid_positive_float?(operation.sigma)
  def semantic?(%Pixelate{} = operation), do: valid_pixelate_size?(operation.size)
  def semantic?(%Monochrome{} = operation), do: valid_monochrome?(operation)
  def semantic?(%Duotone{} = operation), do: valid_duotone?(operation)

  def semantic?(%Colorize{} = operation),
    do:
      valid_effect_intensity?(operation.opacity) and Color.valid?(operation.color) and
        is_boolean(operation.keep_alpha)

  def semantic?(%Brightness{} = operation),
    do: is_integer(operation.value) and operation.value in @brightness_range

  def semantic?(%Contrast{} = operation),
    do: is_number(operation.value) and operation.value > 0

  def semantic?(%Saturation{} = operation),
    do: is_number(operation.value) and operation.value > 0

  def semantic?(%Trim{} = operation), do: valid_trim?(operation)
  def semantic?(%Bitonal{}), do: true
  def semantic?(%Gray{}), do: true
  def semantic?(%SetFocus{point: point}), do: valid_set_focus_point?(point)
  def semantic?(_operation), do: false

  defp valid_set_focus_point?({:coord, x, y}),
    do: match?({:ok, _}, Measure.position(x)) and match?({:ok, _}, Measure.position(y))

  defp valid_set_focus_point?({:anchor, h, v}) when h in @x_anchors and v in @y_anchors, do: true
  defp valid_set_focus_point?(_point), do: false

  defp invalid(operation, attrs), do: {:error, {:invalid_operation, operation, attrs}}

  defp valid_resize?(%Resize{} = operation) do
    with {:ok, mode} <- resize_mode(operation.mode),
         {:ok, _width} <- tagged_resize_dimension(operation.width),
         {:ok, _height} <- tagged_resize_dimension(operation.height),
         :ok <- tagged_dpr_ratio(operation.dpr),
         {:ok, _enlargement} <-
           member(operation.enlargement, @enlargements),
         {:ok, _guide} <- resize_guide(operation.guide),
         :ok <- tagged_offset(operation.x_offset),
         :ok <- tagged_offset(operation.y_offset),
         {:ok, _offsets} <- resize_offsets(mode, operation.x_offset, operation.y_offset),
         :ok <- optional_resize_dimension(operation.min_width),
         :ok <- optional_resize_dimension(operation.min_height),
         :ok <- positive_number(operation.zoom_x),
         :ok <- positive_number(operation.zoom_y),
         :ok <- optional_positive_integer_value(operation.max_width),
         :ok <- optional_positive_integer_value(operation.max_height),
         :ok <- optional_positive_integer_value(operation.max_area) do
      true
    else
      _error -> false
    end
  end

  defp valid_crop_guided?(%CropGuided{} = operation) do
    with {:ok, _width} <- tagged_crop_dimension(operation.width),
         {:ok, _height} <- tagged_crop_dimension(operation.height),
         {:ok, _guide} <- tagged_crop_guide(operation.guide),
         :ok <- tagged_offset(operation.x_offset),
         :ok <- tagged_offset(operation.y_offset),
         {:ok, _aspect_ratio} <- crop_aspect_ratio_option(operation.aspect_ratio),
         {:ok, _enlarge} <- crop_enlarge_option(operation.enlarge) do
      true
    else
      _error -> false
    end
  end

  defp crop_aspect_ratio_option(nil), do: {:ok, nil}

  defp crop_aspect_ratio_option({:ratio, numerator, denominator} = ratio)
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: {:ok, ratio}

  defp crop_aspect_ratio_option(other), do: {:error, {:invalid_crop_aspect_ratio, other}}

  defp crop_enlarge_option(enlarge) when is_boolean(enlarge), do: {:ok, enlarge}
  defp crop_enlarge_option(other), do: {:error, {:invalid_crop_enlarge, other}}

  defp valid_crop_region?(%CropRegion{} = operation) do
    with {:ok, _x} <- tagged_crop_coordinate(operation.x),
         {:ok, _y} <- tagged_crop_coordinate(operation.y),
         {:ok, _width} <- tagged_crop_region_dimension(operation.width),
         {:ok, _height} <- tagged_crop_region_dimension(operation.height) do
      true
    else
      _error -> false
    end
  end

  defp valid_canvas?(%Canvas{} = operation) do
    with {:ok, width} <- tagged_canvas_dimension(operation.width),
         {:ok, height} <- tagged_canvas_dimension(operation.height),
         {:ok, _placement} <- tagged_canvas_placement(operation.placement),
         :ok <- validate_canvas_dimension_pair(width, height, :canvas),
         {:ok, _fill} <- tagged_fill(operation.fill),
         {:ok, _overflow} <- member(operation.overflow, [:reject]),
         :ok <- number(operation.x_offset),
         :ok <- number(operation.y_offset) do
      true
    else
      _error -> false
    end
  end

  defp valid_padding?(%Padding{} = operation) do
    with {:ok, top} <- tagged_padding_side(operation.top),
         {:ok, right} <- tagged_padding_side(operation.right),
         {:ok, bottom} <- tagged_padding_side(operation.bottom),
         {:ok, left} <- tagged_padding_side(operation.left),
         :ok <- validate_positive_padding([top, right, bottom, left]),
         {:ok, _pixel_ratio} <- tagged_padding_pixel_ratio(operation.pixel_ratio),
         {:ok, _fill} <- tagged_fill(operation.fill) do
      true
    else
      _error -> false
    end
  end

  defp valid_background?(%Background{color: color}), do: Color.valid?(color)

  defp valid_trim?(%Trim{threshold: threshold, background: background} = operation) do
    is_number(threshold) and trim_background_valid?(background) and
      is_boolean(operation.equal_hor) and is_boolean(operation.equal_ver)
  end

  defp trim_background_valid?(:auto), do: true
  defp trim_background_valid?(%Color{} = color), do: Color.valid?(color)
  defp trim_background_valid?(_), do: false

  defp valid_positive_float?(value) when is_float(value) and value > 0.0, do: true
  defp valid_positive_float?(_value), do: false

  defp valid_pixelate_size?(value) when is_integer(value) and value > 1, do: true
  defp valid_pixelate_size?(_value), do: false

  defp valid_monochrome?(%Monochrome{intensity: intensity, color: color}) do
    valid_effect_intensity?(intensity) and Color.valid?(color)
  end

  defp valid_duotone?(%Duotone{intensity: intensity, shadow: shadow, highlight: highlight}) do
    valid_effect_intensity?(intensity) and Color.valid?(shadow) and Color.valid?(highlight)
  end

  defp valid_effect_intensity?(value) do
    case effect_intensity(value) do
      {:ok, ^value} -> true
      {:ok, _value} -> false
      {:error, _reason} -> false
    end
  end

  defp validate_known_options(operation, attrs, known_keys) do
    case Keyword.keys(attrs) -- known_keys do
      [] -> :ok
      unknown_keys -> {:error, {:unknown_operation_options, operation, Enum.uniq(unknown_keys)}}
    end
  end

  defp resize_mode(mode) when mode in @resize_modes, do: {:ok, mode}
  defp resize_mode(_mode), do: {:error, :mode}

  defp resize_down(opts) do
    case Keyword.get(opts, :down, false) do
      value when is_boolean(value) -> {:ok, value}
      _ -> {:error, :down}
    end
  end

  defp tagged_resize_dimension(:auto), do: {:ok, :auto}

  defp tagged_resize_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_resize_dimension({:ratio, _num, _den} = ratio),
    do: Measure.dimension(ratio) |> rewrap_dimension()

  defp tagged_resize_dimension({:percent, value}) when is_number(value) and value > 0,
    do: Measure.from_percent(value) |> rewrap_dimension()

  defp tagged_resize_dimension({:scale, value}) when is_number(value) and value > 0,
    do: Measure.from_scale(value) |> rewrap_dimension()

  defp tagged_resize_dimension(_dimension), do: {:error, :dimension}

  # Re-validate the converted ratio as a *dimension* (strictly positive): a tiny
  # positive percent/scale can round to {:ratio, 0, 1}, which is not a valid
  # extent. Measure.dimension/1 rejects it.
  defp rewrap_dimension({:ok, {:ratio, _, _} = ratio}), do: Measure.dimension(ratio)
  defp rewrap_dimension({:error, _}), do: {:error, :dimension}

  defp optional_tagged_resize_dimension(attrs, key) do
    case Keyword.fetch(attrs, key) do
      {:ok, nil} -> {:ok, nil}
      {:ok, value} -> tagged_resize_dimension(value)
      :error -> {:ok, nil}
    end
  end

  defp resize_dpr(value) when is_integer(value) and value > 0, do: {:ok, {:ratio, value, 1}}

  defp resize_dpr(value) when is_float(value) and value > 0.0 do
    value
    |> Float.round(7)
    |> :erlang.float_to_binary(decimals: 7)
    |> decimal_string_ratio()
  end

  defp resize_dpr(value) when is_binary(value), do: decimal_string_ratio(value)
  defp resize_dpr(_value), do: {:error, :dpr}

  defp tagged_dpr_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: :ok

  defp tagged_dpr_ratio(_dpr), do: {:error, :dpr}

  defp tagged_padding_pixel_ratio({:ratio, _numerator, _denominator} = ratio) do
    case tagged_dpr_ratio(ratio) do
      :ok -> {:ok, ratio}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tagged_padding_pixel_ratio({:effective, fallback, mode})
       when mode in @effective_padding_modes do
    case tagged_dpr_ratio(fallback) do
      :ok -> {:ok, {:effective, fallback, mode}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tagged_padding_pixel_ratio(_pixel_ratio), do: {:error, :pixel_ratio}

  defp decimal_string_ratio(value) do
    value
    |> String.split(".", parts: 2)
    |> decimal_string_parts_ratio()
  end

  defp decimal_string_parts_ratio([integer]) do
    with {:ok, numerator} <- parse_non_negative_digits(integer) do
      canonical_dpr_ratio(numerator, 1)
    end
  end

  defp decimal_string_parts_ratio([integer, fraction]) when byte_size(fraction) > 0 do
    with {:ok, integer} <- parse_non_negative_digits(integer),
         {:ok, fraction_value} <- parse_non_negative_digits(fraction) do
      denominator = integer_power(10, byte_size(fraction))
      canonical_dpr_ratio(integer * denominator + fraction_value, denominator)
    end
  end

  defp decimal_string_parts_ratio(_parts), do: {:error, :dpr}

  defp parse_non_negative_digits(value) when byte_size(value) > 0 do
    if digits?(value) do
      {:ok, String.to_integer(value)}
    else
      {:error, :dpr}
    end
  end

  defp parse_non_negative_digits(_value), do: {:error, :dpr}

  defp digits?(value) do
    value
    |> String.to_charlist()
    |> Enum.all?(&(&1 in ?0..?9))
  end

  defp canonical_dpr_ratio(numerator, denominator) when numerator > 0 do
    gcd = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
  end

  defp canonical_dpr_ratio(_numerator, _denominator), do: {:error, :dpr}

  defp resize_guide(:center), do: {:ok, :center}
  defp resize_guide(:carried), do: {:ok, :carried}

  defp resize_guide({:anchor, x, y} = guide) when x in @x_anchors and y in @y_anchors,
    do: {:ok, guide}

  defp resize_guide({:focal, x, y} = guide) do
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, guide}
    else
      {:error, _reason} -> {:error, :guide}
    end
  end

  defp resize_guide(guide), do: smart_guide(guide)

  defp resize_offsets(mode, x_offset, y_offset) when mode in [:cover, :auto],
    do: {:ok, {x_offset, y_offset}}

  defp resize_offsets(_mode, x_offset, y_offset) do
    if zero_offset?(x_offset) and zero_offset?(y_offset) do
      {:ok, {{:pixels, 0.0}, {:pixels, 0.0}}}
    else
      {:error, :offset}
    end
  end

  defp zero_offset?(value) when is_number(value), do: value == 0

  defp zero_offset?({unit, value}) when unit in [:pixels, :scale] and is_number(value),
    do: value == 0

  defp optional_resize_dimension(nil), do: :ok

  defp optional_resize_dimension(dimension) do
    case tagged_resize_dimension(dimension) do
      {:ok, _dimension} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp tagged_crop_dimension(:full_axis), do: {:ok, :full_axis}

  defp tagged_crop_dimension(dimension), do: Measure.dimension(dimension)

  defp tagged_crop_coordinate(coordinate) do
    case Measure.position(coordinate) do
      {:ok, _} = ok -> ok
      {:error, _} -> {:error, :coordinate}
    end
  end

  defp tagged_crop_region_dimension(dimension), do: Measure.dimension(dimension)

  defp tagged_crop_guide(:carried), do: {:ok, :carried}
  defp tagged_crop_guide(guide) when guide in @crop_anchor_guides, do: {:ok, guide}

  defp tagged_crop_guide({:anchor, x, y} = guide) when x in @x_anchors and y in @y_anchors,
    do: {:ok, guide}

  defp tagged_crop_guide({:focal, x, y} = guide) do
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, guide}
    end
  end

  defp tagged_crop_guide(guide), do: smart_guide(guide)

  defp smart_guide(:smart), do: {:ok, :smart}
  defp smart_guide({:smart, :face_assist} = guide), do: {:ok, guide}

  defp smart_guide({:detect, {:all, weights}} = guide) when is_map(weights), do: {:ok, guide}

  defp smart_guide({:detect, {classes, weights}} = guide)
       when is_list(classes) and classes != [] and is_map(weights) do
    if Enum.all?(classes, &is_binary/1) do
      {:ok, guide}
    else
      {:error, :guide}
    end
  end

  defp smart_guide(_guide), do: {:error, :guide}

  defp tagged_canvas_dimension(:auto), do: {:ok, :auto}

  defp tagged_canvas_dimension({:px, value}) when is_integer(value) and value > 0,
    do: {:ok, {:px, value}}

  defp tagged_canvas_dimension({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0,
       do: canonical_ratio(numerator, denominator)

  defp tagged_canvas_dimension(_dimension), do: {:error, :dimension}

  defp tagged_padding_side({:px, value}) when is_integer(value) and value >= 0,
    do: {:ok, {:px, value}}

  defp tagged_padding_side(_side), do: {:error, :padding}

  defp validate_positive_padding(sides) do
    case Enum.any?(sides, fn {:px, value} -> value > 0 end) do
      true -> :ok
      false -> {:error, :padding}
    end
  end

  defp optional_fill(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> tagged_fill(value)
      :error -> {:ok, default}
    end
  end

  defp tagged_fill(:transparent), do: {:ok, :transparent}

  defp tagged_fill({:solid, %Color{} = color}) do
    case Color.valid?(color) do
      true -> {:ok, {:solid, color}}
      false -> {:error, :fill}
    end
  end

  defp tagged_fill(_fill), do: {:error, :fill}

  defp tagged_canvas_placement(placement) when placement in @crop_anchor_guides,
    do: {:ok, placement}

  defp tagged_canvas_placement({:focal, x, y}) do
    with :ok <- tagged_ratio(x),
         :ok <- tagged_ratio(y) do
      {:ok, {:focal, normalize_ratio(x), normalize_ratio(y)}}
    end
  end

  defp tagged_canvas_placement(_placement), do: {:error, :placement}

  defp validate_canvas_dimension_pair(
         {:ratio, _width_numerator, _width_denominator},
         {:ratio, _height_numerator, _height_denominator},
         _context
       ),
       do: :ok

  defp validate_canvas_dimension_pair(
         {:ratio, _width_numerator, _width_denominator},
         _height,
         _context
       ),
       do: {:error, :mixed_canvas_units}

  defp validate_canvas_dimension_pair(
         _width,
         {:ratio, _height_numerator, _height_denominator},
         _context
       ),
       do: {:error, :mixed_canvas_units}

  defp validate_canvas_dimension_pair(_width, _height, _context), do: :ok

  defp tagged_ratio({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator >= 0 and
              denominator > 0,
       do: :ok

  defp tagged_ratio(_ratio), do: {:error, :ratio}

  defp normalize_ratio({:ratio, numerator, denominator}) do
    gcd = Integer.gcd(numerator, denominator)
    {:ratio, div(numerator, gcd), div(denominator, gcd)}
  end

  defp canonical_ratio(numerator, denominator) do
    gcd = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, gcd), div(denominator, gcd)}}
  end

  defp optional_exact(attrs, key, expected) do
    case Keyword.fetch(attrs, key) do
      {:ok, ^expected} -> {:ok, expected}
      {:ok, _value} -> {:error, {key, expected}}
      :error -> {:ok, expected}
    end
  end

  defp optional_member(attrs, key, values, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} -> if value in values, do: {:ok, value}, else: {:error, {key, values}}
      :error -> {:ok, default}
    end
  end

  defp member(value, values) do
    if value in values, do: {:ok, value}, else: {:error, :member}
  end

  defp positive_number(value) when is_number(value) and value > 0, do: :ok
  defp positive_number(_value), do: {:error, :number}

  defp number(value) when is_number(value), do: :ok
  defp number(_value), do: {:error, :number}

  defp effect_intensity({:ratio, numerator, denominator})
       when is_integer(numerator) and is_integer(denominator) and numerator > 0 and
              denominator > 0 and numerator <= denominator do
    divisor = Integer.gcd(numerator, denominator)
    {:ok, {:ratio, div(numerator, divisor), div(denominator, divisor)}}
  end

  defp effect_intensity(_value), do: {:error, :intensity}

  defp tagged_offset(value) when is_number(value), do: :ok

  defp tagged_offset({unit, value}) when unit in [:pixels, :scale] and is_number(value),
    do: :ok

  defp tagged_offset(_value), do: {:error, :offset}

  defp numeric(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) and value > 0 -> {:ok, value}
      {:ok, _value} -> {:error, key}
      :error -> {:ok, default}
    end
  end

  defp optional_positive_integer(attrs, key) do
    case Keyword.get(attrs, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, key}
    end
  end

  defp optional_positive_integer_value(nil), do: :ok
  defp optional_positive_integer_value(value) when is_integer(value) and value > 0, do: :ok
  defp optional_positive_integer_value(_value), do: {:error, :max_bound}

  defp signed_numeric(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) -> {:ok, value}
      {:ok, _value} -> {:error, key}
      :error -> {:ok, default}
    end
  end

  defp offset(attrs, key, default) do
    case Keyword.fetch(attrs, key) do
      {:ok, value} when is_number(value) ->
        {:ok, value}

      {:ok, {unit, value}} when unit in [:pixels, :scale] and is_number(value) ->
        {:ok, {unit, value}}

      {:ok, _value} ->
        {:error, key}

      :error ->
        {:ok, default}
    end
  end

  defp integer_power(base, exponent) do
    Enum.reduce(1..exponent//1, 1, fn _step, product -> product * base end)
  end
end
