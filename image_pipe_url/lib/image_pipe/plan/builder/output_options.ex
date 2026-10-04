defmodule ImagePipe.Plan.Builder.OutputOptions do
  @moduledoc false

  alias ImagePipe.Plan.Builder.Options
  alias ImagePipe.Plan.Output.{AvifOptions, JpegOptions, PngOptions, WebpOptions}

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

  def format_qualities([]), do: {:error, "expected at least one format; use :unset to clear"}

  def format_qualities(values) do
    schema = Enum.map(@formats, &{&1, @quality})

    with {:ok, values} <- Options.validate(values, schema) do
      {:ok, Map.new(values, fn {format, quality} -> {format, {:quality, quality}} end)}
    end
  end

  def autoquality(enabled) when is_boolean(enabled), do: {:ok, enabled}

  def autoquality(target) when is_number(target) and target > 0 and target <= 100,
    do: {:ok, target * 1.0}

  def autoquality(_value), do: {:error, "expected a boolean or a target above 0 and up to 100"}

  def encoder([], _format), do: {:error, "expected at least one option; use :unset to clear"}

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
