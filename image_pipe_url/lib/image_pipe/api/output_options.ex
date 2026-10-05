defmodule ImagePipe.API.OutputOptions do
  @moduledoc false

  alias ImagePipe.API.SerializedValue
  alias ImagePipe.API.Value
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}

  @formats %{
    "avif" => :avif,
    "webp" => :webp,
    "jpeg" => :jpeg,
    "png" => :png
  }

  @encoder_modules %{
    jpeg: JpegOptions,
    png: PngOptions,
    webp: WebpOptions,
    avif: AvifOptions
  }
  @encoder_schemas Map.new(@encoder_modules, fn {format, module} ->
                     fields =
                       Map.new(module.schema(), fn {field, options} ->
                         name =
                           case {format, field} do
                             {:jpeg, :interlace} -> "progressive"
                             {_, :subsample_mode} -> "subsample"
                             {_, field} -> SerializedValue.scalar(field)
                           end

                         parser =
                           case Keyword.fetch!(options, :type) do
                             :boolean ->
                               :boolean

                             {:in, [first | _] = values} when is_atom(first) ->
                               {:enum, Map.new(values, &{Atom.to_string(&1), &1})}

                             {:in, values} ->
                               {:integer, values}
                           end

                         {name, {field, parser}}
                       end)

                     {format, fields}
                   end)

  @doc false
  def serialize_encoder(options, format) do
    format
    |> encoder_schema()
    |> Enum.sort()
    |> Enum.flat_map(fn {name, {field, _parser}} ->
      case Map.fetch!(options, field) do
        nil -> []
        true -> [name]
        value -> [name <> ":" <> SerializedValue.scalar(value)]
      end
    end)
    |> Enum.join(",")
  end

  defp encoder_schema(format), do: Map.fetch!(@encoder_schemas, format)

  @spec parse_format_qualities(String.t()) :: {:ok, map()} | :error
  def parse_format_qualities(string) do
    with {:ok, pairs} <- parse_unique_items(string, &format_quality_item/1) do
      {:ok, Map.new(pairs)}
    end
  end

  @spec parse_autoquality(String.t()) :: {:ok, float()} | :error
  def parse_autoquality(string) do
    case Value.number(string) do
      {:ok, number} when number > 0 and number <= 100 -> {:ok, number * 1.0}
      _invalid -> :error
    end
  end

  @spec parse_max_bytes(String.t()) :: {:ok, pos_integer()} | :error
  def parse_max_bytes(string), do: positive_integer(string)

  @spec parse_dpi(String.t()) :: {:ok, 1..65_535} | :error
  def parse_dpi(string) do
    case positive_integer(string) do
      {:ok, dpi} when dpi <= 65_535 -> {:ok, dpi}
      _invalid -> :error
    end
  end

  @spec parse_jpeg_options(String.t()) :: {:ok, JpegOptions.t()} | :error
  def parse_jpeg_options(string), do: parse_codec(string, :jpeg)

  @spec parse_png_options(String.t()) :: {:ok, PngOptions.t()} | :error
  def parse_png_options(string), do: parse_codec(string, :png)

  @spec parse_webp_options(String.t()) :: {:ok, WebpOptions.t()} | :error
  def parse_webp_options(string), do: parse_codec(string, :webp)

  @spec parse_avif_options(String.t()) :: {:ok, AvifOptions.t()} | :error
  def parse_avif_options(string), do: parse_codec(string, :avif)

  defp format_quality_item(item) do
    with [format, quality] <- String.split(item, ":", parts: 3),
         {:ok, format} <- Map.fetch(@formats, format),
         {:ok, quality} <- quality(quality) do
      {:ok, {format, {:quality, quality}}}
    else
      _invalid -> :error
    end
  end

  defp parse_codec(string, format) do
    module = Map.fetch!(@encoder_modules, format)
    schema = encoder_schema(format)

    with {:ok, pairs} <- parse_unique_items(string, &codec_item(&1, schema)) do
      {:ok, struct(module, Map.new(pairs))}
    end
  end

  defp codec_item(item, schema) do
    case String.split(item, ":", parts: 3) do
      [name] -> codec_bare_item(name, schema)
      [name, value] -> codec_value_item(name, value, schema)
      _invalid -> :error
    end
  end

  defp codec_bare_item(name, schema) do
    case Map.fetch(schema, name) do
      {:ok, {field, :boolean}} -> {:ok, {field, true}}
      _invalid -> :error
    end
  end

  defp codec_value_item(name, "false", schema) do
    case Map.fetch(schema, name) do
      {:ok, {field, :boolean}} -> {:ok, {field, false}}
      _invalid -> :error
    end
  end

  defp codec_value_item(name, value, schema) do
    with {:ok, {field, parser}} when parser != :boolean <- Map.fetch(schema, name),
         {:ok, value} <- parse_codec_value(value, parser) do
      {:ok, {field, value}}
    else
      _invalid -> :error
    end
  end

  defp parse_codec_value(value, {:enum, values}), do: Map.fetch(values, value)

  defp parse_codec_value(value, {:integer, allowed}) do
    with {:ok, integer} <- nonnegative_integer(value),
         true <- integer in allowed do
      {:ok, integer}
    else
      _invalid -> :error
    end
  end

  defp parse_unique_items(string, parser) when is_binary(string),
    do: parse_unique_items(String.split(string, ",", trim: false), parser)

  defp parse_unique_items([], _parser), do: {:ok, []}
  defp parse_unique_items([""], _parser), do: :error

  defp parse_unique_items(items, parser) when is_list(items) do
    Enum.reduce_while(items, {:ok, [], MapSet.new()}, fn item, {:ok, pairs, seen} ->
      case parser.(item) do
        {:ok, pair} ->
          add_unique_pair(pair, pairs, seen)

        :error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, pairs, _seen} -> {:ok, Enum.reverse(pairs)}
      :error -> :error
    end
  end

  defp add_unique_pair({key, _value} = pair, pairs, seen) do
    if MapSet.member?(seen, key) do
      {:halt, :error}
    else
      {:cont, {:ok, [pair | pairs], MapSet.put(seen, key)}}
    end
  end

  defp quality(string) do
    with {:ok, quality} <- nonnegative_integer(string),
         true <- quality in 1..100 do
      {:ok, quality}
    else
      _invalid -> :error
    end
  end

  defp positive_integer(string) do
    with {:ok, integer} <- nonnegative_integer(string),
         true <- integer > 0 do
      {:ok, integer}
    else
      _invalid -> :error
    end
  end

  defp nonnegative_integer(string) do
    case Value.number(string) do
      {:ok, integer} when is_integer(integer) and integer >= 0 -> {:ok, integer}
      _invalid -> :error
    end
  end
end
