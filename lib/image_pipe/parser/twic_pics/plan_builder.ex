defmodule ImagePipe.Parser.TwicPics.PlanBuilder do
  @moduledoc false

  alias ImagePipe.Parser.TwicPics.Output
  alias ImagePipe.Parser.TwicPics.Units
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  @initial %{ops: [], guide: :carried, format: :auto, quality: :default, debug?: false}

  @spec to_plan(Source.t(), [{String.t(), String.t()}]) :: {:ok, Plan.t()} | {:error, term()}
  def to_plan(source, chain) when is_list(chain) do
    with {:ok, acc} <- fold(chain),
         {:ok, output} <- Output.build(%{format: acc.format, quality: acc.quality}) do
      {:ok,
       %Plan{
         source: source,
         pipelines: [%Pipeline{operations: Enum.reverse(acc.ops)}],
         output: output,
         auto_rotate: true,
         response: %Response{debug?: acc.debug?}
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
  defp apply_segment("debug", args, acc), do: debug(args, acc)
  defp apply_segment(name, _args, _acc), do: {:error, {:unsupported_transform, name}}

  # `debug=1` opts the response into `X-ImagePipe-*` debug headers (honored only
  # under the `allow_debug_headers: true` mount flag). It is an ImagePipe
  # extension with no TwicPics counterpart, sets `Plan.Response.debug?`, and
  # emits no operation — so it is order-independent and never affects produced
  # bytes, the cache key, or the ETag. TwicPics has no request signing, so the
  # trigger is unprotected; see docs/twicpics_support_matrix.md.
  defp debug(args, acc) do
    case ImagePipe.Parser.parse_boolean(args) do
      {:ok, debug?} -> {:ok, %{acc | debug?: debug?}}
      {:error, _} -> {:error, {:invalid_debug, args}}
    end
  end

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
      # crop@coords resets the carried focus to the crop-result centre at
      # execution; the running guide stays :carried so the next consumer reads it.
      push(%{acc | guide: :carried}, op)
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
  # Live TwicPics accepts `focus=center` (resolves to the centre point) even though
  # the documented anchor list omits it; emit a centre-anchor SetFocus.
  defp focus("center", acc), do: emit_focus({:anchor, :center, :center}, acc)

  defp focus(args, acc) do
    case Units.anchor(args) do
      {:ok, {:anchor, h, v}} -> emit_focus({:anchor, h, v}, acc)
      {:error, _} -> focus_coordinates(args, acc)
    end
  end

  # A coordinate focus (literal px, relative p/s, or mixed) emits a positional
  # SetFocus that resolves its units against the running frame at execution and
  # carries the resolved point. Out-of-range positives are clamped there; negative
  # coordinates are rejected by Units before this point.
  defp focus_coordinates(args, acc) do
    with {:ok, {x, y}} <- Units.coordinates(args),
         {:ok, op} <- Operation.set_focus({:coord, x, y}) do
      {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
    else
      _ -> {:error, {:unsupported_focus, args}}
    end
  end

  defp emit_focus(anchor, acc) do
    with {:ok, op} <- Operation.set_focus(anchor) do
      {:ok, %{acc | ops: [op | acc.ops], guide: :carried}}
    end
  end

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
