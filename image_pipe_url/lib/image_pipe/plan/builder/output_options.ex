defmodule ImagePipe.Plan.Builder.OutputOptions do
  @moduledoc false

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Builder.Values
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Output.QualitySearch.Metric

  @formats [:jpeg, :png, :webp, :avif]
  @quality [type: {:in, 1..100}]

  def schema do
    [
      terminal: [type: {:custom, __MODULE__, :terminal, []}],
      format: [type: {:in, @formats}],
      quality: @quality,
      metadata: [type: {:in, [:strip, :copyright, :keep]}],
      color_profile: [
        type:
          {:in,
           [
             :strip,
             :preserve_source,
             {:convert, :srgb},
             {:convert, :display_p3},
             {:convert, :adobe_rgb}
           ]}
      ],
      hdr: [type: {:in, [:tone_map, :preserve]}],
      format_qualities: [type: {:custom, __MODULE__, :format_qualities, []}],
      autoquality: [type: {:custom, __MODULE__, :autoquality, []}],
      max_bytes: [type: :pos_integer],
      dpi: [type: {:in, 1..65_535}],
      jpeg_options: [type: {:custom, __MODULE__, :encoder, [:jpeg]}],
      png_options: [type: {:custom, __MODULE__, :encoder, [:png]}],
      webp_options: [type: {:custom, __MODULE__, :encoder, [:webp]}],
      avif_options: [type: {:custom, __MODULE__, :encoder, [:avif]}]
    ]
  end

  def terminal(terminal) when terminal in [:image, :info, :blurhash, :lqip_css],
    do: {:ok, terminal}

  def terminal({:info, [_ | _] = placeholders} = terminal) do
    if Enum.all?(placeholders, &(&1 in [:blurhash, :lqip_css])) and
         placeholders == Enum.uniq(placeholders),
       do: {:ok, terminal},
       else: terminal_error()
  end

  def terminal(_value), do: terminal_error()

  defp terminal_error,
    do:
      {:error,
       "expected :image, :blurhash, :lqip_css, :info, or {:info, placeholders} with distinct :blurhash/:lqip_css"}

  def format_qualities(values) do
    schema = Enum.map(@formats, &{&1, @quality})

    with {:ok, values} <- Options.validate(values, schema) do
      {:ok, Map.new(values, fn {format, quality} -> {format, {:quality, quality}} end)}
    end
  end

  def autoquality(:none), do: {:ok, :none}

  def autoquality({method, options}) when method in [:size, :ssimulacra2, :butteraugli] do
    with {:ok, fields} <- Options.validate(options, quality_schema(method)),
         :ok <- quality_bracket(fields) do
      fields =
        for key <- [:target, :min_quality, :max_quality, :allowed_error],
            Keyword.has_key?(fields, key),
            do: {key, Keyword.fetch!(fields, key)}

      {:ok, {method, fields}}
    end
  end

  def autoquality(_value), do: {:error, "expected :none or {method, options}"}

  defp quality_schema(method) do
    [min_quality: @quality, max_quality: @quality] ++ quality_target_schema(method)
  end

  defp quality_target_schema(:size), do: [target: [type: :pos_integer]]

  defp quality_target_schema(method) do
    [
      target: [type: {:custom, __MODULE__, :metric_target, [method]}],
      allowed_error: [type: {:custom, Values, :cast, [:nonnegative]}]
    ]
  end

  def metric_target(value, method) do
    {lo, hi} = Metric.target_range(method)

    case is_number(value) and value >= lo and value <= hi do
      true -> Values.cast(value, :nonnegative)
      false -> {:error, "target is outside the metric range"}
    end
  end

  defp quality_bracket(fields) do
    case {Keyword.get(fields, :min_quality), Keyword.get(fields, :max_quality)} do
      {min, max} when is_integer(min) and is_integer(max) and min > max ->
        {:error, "min_quality must not exceed max_quality"}

      _valid ->
        :ok
    end
  end

  def encoder(options, format) do
    module = encoder_module(format)

    with {:ok, values} <- Options.validate(options, module.schema()),
         do: {:ok, struct!(module, values)}
  end

  defp encoder_module(:jpeg), do: JpegOptions
  defp encoder_module(:png), do: PngOptions
  defp encoder_module(:webp), do: WebpOptions
  defp encoder_module(:avif), do: AvifOptions
end
