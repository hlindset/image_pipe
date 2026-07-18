defmodule ImagePipe.Dialect.TwicPics.RequestBuilder do
  @moduledoc false

  alias ImagePipe.Dialect.TwicPics.Output
  alias ImagePipe.Dialect.TwicPics.Request
  alias ImagePipe.Dialect.TwicPics.Units
  alias ImagePipe.Plan.Operation
  alias ImagePipe.Plan.Response
  alias ImagePipe.Plan.Source

  @initial %{steps: [], format: :auto, quality: :default, debug?: false}

  @spec build(Source.t(), [{String.t(), String.t()}], keyword()) ::
          {:ok, Request.t()} | {:error, term()}
  def build(source, chain, config) when is_list(chain) do
    with {:ok, acc} <- fold(chain),
         {:ok, output} <- Output.build(%{format: acc.format, quality: acc.quality}),
         {:ok, output} <- ImagePipe.Config.apply_to_output(output, config) do
      {:ok,
       %Request{
         source: source,
         steps: Enum.reverse(acc.steps),
         output: output,
         response: %Response{debug?: acc.debug?},
         auto_rotate: Keyword.fetch!(config, :auto_rotate)
       }}
    end
  end

  # ex_dna:disable-for-next-line
  defp fold(chain) do
    Enum.reduce_while(chain, {:ok, @initial}, fn {name, args}, {:ok, acc} ->
      case apply_segment(name, args, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # ex_dna:disable-for-next-line
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

  defp debug(args, acc) do
    case parse_boolean(args) do
      {:ok, debug?} -> {:ok, %{acc | debug?: debug?}}
      {:error, _reason} -> {:error, {:invalid_debug, args}}
    end
  end

  # ex_dna:disable-for-next-line
  defp parse_boolean(value) when value in ["1", "t", "true"], do: {:ok, true}
  defp parse_boolean(value) when value in ["0", "f", "false"], do: {:ok, false}
  defp parse_boolean(value), do: {:error, {:invalid_boolean, value}}

  defp resize(args, acc) do
    if String.contains?(args, ":") do
      {:error, {:unsupported_transform_ratio, "resize"}}
    else
      with {:ok, {width, height}} <- Units.size(args),
           {mode, width, height} <- resize_mode(width, height),
           {:ok, operation} <- Operation.resize(mode, width, height) do
        push(acc, {:operation, operation})
      end
    end
  end

  # ex_dna:disable-for-next-line
  defp resize_mode(width, :auto), do: {:fit, width, :auto}
  defp resize_mode(:auto, height), do: {:fit, :auto, height}
  defp resize_mode(width, height), do: {:stretch, width, height}

  defp cover(args, acc) do
    if String.contains?(args, ":") do
      with {:ok, {:ratio, _, _} = ratio} <- Units.ratio(args),
           {:ok, operation} <-
             Operation.crop_guided(:full_axis, :full_axis, :center, aspect_ratio: ratio) do
        push(acc, {:focused, operation})
      end
    else
      with {:ok, {width, height}} <- Units.size(args),
           {:ok, operation} <- Operation.resize(:cover, width, height, guide: :center) do
        push(acc, {:focused, operation})
      end
    end
  end

  defp contain(args, acc) do
    with {:ok, {width, height}} <- Units.size(args),
         {:ok, operation} <- Operation.resize(:fit, width, height) do
      push(acc, {:operation, operation})
    end
  end

  defp inside(args, acc) do
    if String.contains?(args, ":") do
      with {:ok, {:ratio, width, height}} <- Units.ratio(args),
           {:ok, operation} <-
             Operation.canvas(
               {:ratio, width, 1},
               {:ratio, height, 1},
               :center,
               fill: :transparent
             ) do
        push(acc, {:operation, operation})
      end
    else
      with {:ok, {width, height}} <- Units.size(args),
           :ok <- pixels_only([width, height], :inside),
           {:ok, resize} <- Operation.resize(:fit, width, height),
           {:ok, canvas} <- Operation.canvas(width, height, :center, fill: :transparent),
           {:ok, acc} <- push(acc, {:operation, resize}) do
        push(acc, {:operation, canvas})
      end
    end
  end

  defp crop(args, acc) do
    case String.split(args, "@", parts: 2) do
      [size] -> crop_guided(size, acc)
      [size, coordinates] -> crop_region(size, coordinates, acc)
    end
  end

  defp crop_guided(size, acc) do
    with {:ok, {width, height}} <- Units.crop_size(size),
         {:ok, operation} <- Operation.crop_guided(width, height, :center) do
      push(acc, {:focused, operation})
    end
  end

  defp crop_region(size, coordinates, acc) do
    with {:ok, {width, height}} <- region_size(size),
         {:ok, {x, y}} <- Units.coordinates(coordinates),
         {:ok, operation} <- Operation.crop_region(x, y, width, height) do
      push(acc, {:operation, operation})
    end
  end

  # ex_dna:disable-for-next-line
  defp region_size(size) do
    case Units.size(size) do
      {:ok, {width, height}} when width != :auto and height != :auto ->
        {:ok, {width, height}}

      {:ok, _partial} ->
        {:error, {:unsupported_crop_region_size, size}}

      {:error, _reason} = error ->
        error
    end
  end

  defp focus("auto", acc), do: push(acc, :set_auto_focus)
  defp focus("center", acc), do: push(acc, {:set_focus, {:anchor, :center, :center}})

  defp focus(args, acc) do
    case Units.anchor(args) do
      {:ok, {:anchor, horizontal, vertical}} ->
        push(acc, {:set_focus, {:anchor, horizontal, vertical}})

      {:error, _reason} ->
        focus_coordinates(args, acc)
    end
  end

  defp focus_coordinates(args, acc) do
    case Units.coordinates(args) do
      {:ok, {x, y}} -> push(acc, {:set_focus, {:coord, x, y}})
      {:error, _reason} -> {:error, {:unsupported_focus, args}}
    end
  end

  # ex_dna:disable-for-next-line
  defp output(args, acc) do
    with {:ok, format} <- Output.format(args), do: {:ok, %{acc | format: format}}
  end

  defp quality(args, acc) do
    with {:ok, quality} <- Output.quality(args), do: {:ok, %{acc | quality: quality}}
  end

  defp push(acc, step), do: {:ok, %{acc | steps: [step | acc.steps]}}

  defp pixels_only(dimensions, transform) do
    if Enum.all?(dimensions, &pixel_dimension?/1),
      do: :ok,
      else: {:error, {:unsupported_unit, transform}}
  end

  defp pixel_dimension?({:px, _value}), do: true
  defp pixel_dimension?(:auto), do: true
  defp pixel_dimension?(:full_axis), do: true
  defp pixel_dimension?(_dimension), do: false
end
