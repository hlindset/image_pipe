defmodule ImagePipe.Parser.TwicPics.PlanBuilder do
  @moduledoc false

  alias ImagePipe.Parser.TwicPics.Output
  alias ImagePipe.Parser.TwicPics.Units
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source

  @initial %{ops: [], guide: :center, format: :auto, quality: :default}

  @spec to_plan(Source.t(), [{String.t(), String.t()}]) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(source, chain) when is_list(chain) do
    with {:ok, acc} <- fold(chain),
         {:ok, output} <- Output.build(%{format: acc.format, quality: acc.quality}) do
      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: Enum.reverse(acc.ops)}],
         output: output,
         auto_rotate: true
       }}
    end
  end

  defp fold(chain) do
    Enum.reduce_while(chain, {:ok, @initial}, fn {name, args}, {:ok, acc} ->
      case apply_segment(name, args, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp apply_segment("resize", args, acc), do: resize(args, acc)
  defp apply_segment("cover", args, acc), do: cover(args, acc)
  defp apply_segment("contain", args, acc), do: contain(args, acc)
  defp apply_segment("inside", args, acc), do: inside(args, acc)
  defp apply_segment("crop", args, acc), do: crop(args, acc)
  defp apply_segment("focus", args, acc), do: focus(args, acc)
  defp apply_segment("output", args, acc), do: output(args, acc)
  defp apply_segment("quality", args, acc), do: quality(args, acc)
  defp apply_segment(name, _args, _acc), do: {:error, {:unsupported_transform, name}}

  defp resize(args, acc) do
    if String.contains?(args, ":") do
      {:error, {:unsupported_transform_ratio, "resize"}}
    else
      with {:ok, {w, h}} <- Units.size(args),
           {mode, w, h} <- resize_mode(w, h),
           {:ok, op} <- Operation.resize(mode, w, h) do
        push(acc, op)
      end
    end
  end

  defp resize_mode(w, :auto), do: {:fit, w, :auto}
  defp resize_mode(:auto, h), do: {:fit, :auto, h}
  defp resize_mode(w, h), do: {:stretch, w, h}

  defp cover(args, acc) do
    if String.contains?(args, ":") do
      with {:ok, {:ratio, _, _} = ratio} <- Units.ratio(args),
           {:ok, op} <-
             Operation.crop_guided(:full_axis, :full_axis, acc.guide, aspect_ratio: ratio) do
        push(acc, op)
      end
    else
      with {:ok, {w, h}} <- Units.size(args),
           {:ok, op} <- Operation.resize(:cover, w, h, guide: acc.guide) do
        push(acc, op)
      end
    end
  end

  defp contain(args, acc) do
    with {:ok, {w, h}} <- Units.size(args),
         {:ok, op} <- Operation.resize(:fit, w, h) do
      push(acc, op)
    end
  end

  defp inside(args, acc) do
    if String.contains?(args, ":") do
      # Pad-to-ratio: fit the whole image inside a box of this aspect ratio and
      # letterbox with transparent borders. The Canvas ratio rule reads each axis
      # as a magnitude, so the W:H aspect is expressed as width {:ratio, w, 1},
      # height {:ratio, h, 1} (a single shared ratio on both axes is a 1:1 box).
      with {:ok, {:ratio, w, h}} <- Units.ratio(args),
           {:ok, op} <-
             Operation.canvas({:ratio, w, 1}, {:ratio, h, 1}, :center, fill: :transparent) do
        push(acc, op)
      end
    else
      with {:ok, {w, h}} <- Units.size(args),
           :ok <- pixels_only([w, h], :inside),
           {:ok, resize} <- Operation.resize(:fit, w, h),
           {:ok, canvas} <- Operation.canvas(w, h, :center, fill: :transparent),
           {:ok, acc} <- push(acc, resize) do
        push(acc, canvas)
      end
    end
  end

  defp crop(args, acc) do
    case String.split(args, "@", parts: 2) do
      [size] -> crop_guided(size, acc)
      [size, coords] -> crop_region(size, coords, acc)
    end
  end

  defp crop_guided(size, acc) do
    with {:ok, {w, h}} <- Units.crop_size(size),
         {:ok, op} <- Operation.crop_guided(w, h, acc.guide) do
      push(acc, op)
    end
  end

  defp crop_region(size, coords, acc) do
    with {:ok, {w, h}} <- region_size(size),
         {:ok, {x, y}} <- crop_coordinates(coords),
         {:ok, op} <- Operation.crop_region(x, y, w, h) do
      # explicit coordinates reset the focus to center
      push(%{acc | guide: :center}, op)
    end
  end

  # A region crop (`crop=WxH@XxY`) requires both axes explicit — an omitted axis
  # (`crop=100@…`, which `Units.size` yields as `:auto`) is not a valid region
  # size.
  defp region_size(size) do
    case Units.size(size) do
      {:ok, {w, h}} when w != :auto and h != :auto -> {:ok, {w, h}}
      {:ok, _partial} -> {:error, {:unsupported_crop_region_size, size}}
      {:error, _reason} = error -> error
    end
  end

  defp crop_coordinates(coords), do: Units.coordinates(coords)

  # Content-aware subject focus. TwicPics leaves the algorithm unspecified ("chosen
  # automagically"); ImagePipe approximates it with the `{:smart, :face_assist}`
  # guide -- libvips attention saliency blended toward detected faces, the same
  # engine as imgproxy `g:sm` with face detection. Gracefully falls back to plain
  # attention when no detector is configured. Steers the next `cover` / `crop`;
  # emits no operation.
  defp focus("auto", acc), do: {:ok, %{acc | guide: {:smart, :face_assist}}}
  defp focus("center", _acc), do: {:error, {:unsupported_focus, "center"}}

  defp focus(args, acc) do
    case Units.anchor(args) do
      {:ok, guide} -> {:ok, %{acc | guide: guide}}
      {:error, _} -> focus_coordinates(args, acc)
    end
  end

  # Relative (p/s) coordinate focus -> focal ratio guide. Bare-pixel coordinates
  # need running-dim-at-focus-position resolution and are deferred (separate issue).
  defp focus_coordinates(args, acc) do
    with {:ok, {x, y}} <- Units.coordinates(args),
         {:ok, fx} <- focal_ratio(x),
         {:ok, fy} <- focal_ratio(y) do
      {:ok, %{acc | guide: {:focal, fx, fy}}}
    else
      _ -> {:error, {:unsupported_focus, args}}
    end
  end

  # In-range relative focus only. A ratio > 1 (e.g. 150p) is an out-of-image focus
  # point and must be rejected here (the plan-construction gate has no upper bound,
  # so it would otherwise fail only late in crop.ex after source fetch). Bare-px deferred.
  defp focal_ratio({:ratio, num, den}) when num <= den, do: {:ok, {:ratio, num, den}}
  defp focal_ratio(_measure), do: {:error, :out_of_range_or_deferred_focus}

  defp output(args, acc) do
    with {:ok, format} <- Output.format(args), do: {:ok, %{acc | format: format}}
  end

  defp quality(args, acc) do
    with {:ok, quality} <- Output.quality(args), do: {:ok, %{acc | quality: quality}}
  end

  defp push(acc, op), do: {:ok, %{acc | ops: [op | acc.ops]}}

  # `inside` accepts pixel dimensions only. Its resize+canvas composition
  # entangles relative units with canvas aspect-ratio semantics, so percent/scale
  # dimensions are rejected here.
  defp pixels_only(dims, transform) do
    if Enum.all?(dims, &pixel_dimension?/1),
      do: :ok,
      else: {:error, {:unsupported_unit, transform}}
  end

  defp pixel_dimension?({:px, _}), do: true
  defp pixel_dimension?(:auto), do: true
  defp pixel_dimension?(:full_axis), do: true
  defp pixel_dimension?(_), do: false
end
