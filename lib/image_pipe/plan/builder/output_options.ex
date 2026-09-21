defmodule ImagePipe.Plan.Builder.OutputOptions do
  @moduledoc false

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Builder.Values
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, JxlOptions, PngOptions, WebpOptions}
  alias ImagePipe.Plan.Output.QualitySearch.Metric

  @formats [:jpeg, :png, :webp, :avif, :jpeg_xl]
  @quality [type: {:in, 1..100}]

  def schema do
    [
      terminal: [type: {:in, [:image, :info, :blurhash, :lqip_css]}],
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
      jpeg_options: [type: {:custom, __MODULE__, :encoder, [:jpeg]}],
      png_options: [type: {:custom, __MODULE__, :encoder, [:png]}],
      webp_options: [type: {:custom, __MODULE__, :encoder, [:webp]}],
      avif_options: [type: {:custom, __MODULE__, :encoder, [:avif]}],
      jxl_options: [type: {:custom, __MODULE__, :encoder, [:jpeg_xl]}]
    ]
  end

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
    {module, schema} = encoder_schema(format)

    with {:ok, values} <- Options.validate(options, schema), do: {:ok, struct!(module, values)}
  end

  defp encoder_schema(:jpeg) do
    {JpegOptions,
     [
       interlace: [type: :boolean],
       subsample_mode: [type: {:in, [:auto, :on, :off]}],
       trellis_quant: [type: :boolean],
       overshoot_deringing: [type: :boolean],
       optimize_scans: [type: :boolean],
       quant_table: [type: {:in, 0..8}]
     ]}
  end

  defp encoder_schema(:png) do
    {PngOptions,
     [
       interlace: [type: :boolean],
       palette: [type: :boolean],
       bitdepth: [type: {:in, [1, 2, 4, 8, 16]}],
       filter: [type: {:in, [:none, :sub, :up, :avg, :paeth, :all]}]
     ]}
  end

  defp encoder_schema(:webp) do
    {WebpOptions,
     [
       lossless: [type: :boolean],
       near_lossless: [type: :boolean],
       smart_subsample: [type: :boolean],
       preset: [type: {:in, [:default, :photo, :picture, :drawing, :icon, :text]}],
       effort: [type: {:in, 0..6}]
     ]}
  end

  defp encoder_schema(:avif),
    do:
      {AvifOptions,
       [subsample_mode: [type: {:in, [:auto, :on, :off]}], effort: [type: {:in, 0..9}]]}

  defp encoder_schema(:jpeg_xl), do: {JxlOptions, [effort: [type: {:in, 1..9}]]}
end
