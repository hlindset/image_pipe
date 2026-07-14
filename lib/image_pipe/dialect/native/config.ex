defmodule ImagePipe.Dialect.Native.Config do
  @moduledoc false

  alias ImagePipe.Cache
  alias ImagePipe.Format
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @default_max_body_bytes 10_000_000
  @default_max_input_pixels 40_000_000

  @validated_option_keys [
    :keys,
    :presets,
    :on_inert_option,
    :storage_inputs,
    :max_body_bytes,
    :max_input_pixels,
    :telemetry_prefix,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl,
    :format_order
  ]
  @known_option_keys @validated_option_keys ++ [:cache, :sources]
  @options_schema NimbleOptions.new!(
                    keys: [
                      type: {:list, {:custom, __MODULE__, :validate_hex_key, []}},
                      default: []
                    ],
                    presets: [
                      type: {:map, :string, :string},
                      default: %{}
                    ],
                    on_inert_option: [
                      type: {:in, [:reject, :ignore]},
                      default: :reject
                    ],
                    storage_inputs: [
                      type: {:list, {:custom, __MODULE__, :validate_storage_input, []}},
                      default: []
                    ],
                    max_body_bytes: [
                      type: :pos_integer,
                      default: @default_max_body_bytes
                    ],
                    max_input_pixels: [
                      type: :pos_integer,
                      default: @default_max_input_pixels
                    ],
                    telemetry_prefix: [
                      type: {:custom, __MODULE__, :validate_telemetry_prefix, []},
                      default: Telemetry.default_prefix()
                    ],
                    auto_avif: [
                      type: :boolean,
                      default: true
                    ],
                    auto_webp: [
                      type: :boolean,
                      default: true
                    ],
                    auto_jpeg_xl: [
                      type: :boolean,
                      default: true
                    ],
                    format_order: [
                      type: {:custom, __MODULE__, :validate_format_order, []}
                    ]
                  )

  @doc false
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) when is_list(opts) do
    opts
    |> Cache.validate_config!()
    |> Source.validate_config!()
    |> reject_unknown_opts!()
    |> validate_known_opts!()
    |> reject_unimplemented_on_inert_option!()
  end

  @doc false
  def validate_hex_key(value) when is_binary(value) and value != "" do
    case Base.decode16(value, case: :mixed) do
      {:ok, _binary} -> {:ok, value}
      :error -> {:error, "expected a hex-encoded string, got: #{inspect(value)}"}
    end
  end

  def validate_hex_key(value),
    do: {:error, "expected a hex-encoded string, got: #{inspect(value)}"}

  @doc false
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(value),
    do:
      {:error,
       "expected {:header, name} or {:cookie, name} with a non-empty string name, got: #{inspect(value)}"}

  @doc false
  def validate_telemetry_prefix(telemetry_prefix) do
    if telemetry_prefix_valid?(telemetry_prefix) do
      {:ok, telemetry_prefix}
    else
      {:error, "expected a non-empty list of atoms"}
    end
  end

  defp telemetry_prefix_valid?([_ | _] = list), do: Enum.all?(list, &is_atom/1)
  defp telemetry_prefix_valid?(_not_a_nonempty_list), do: false

  @doc false
  def validate_format_order(order) do
    modern_formats = Format.modern_formats()

    with true <- is_list(order),
         true <- order != [],
         true <- Enum.all?(order, &(&1 in modern_formats)),
         true <- Enum.uniq(order) |> length() == length(order) do
      {:ok, order}
    else
      false -> format_order_error(order, modern_formats)
    end
  end

  defp format_order_error(order, _modern_formats) when not is_list(order) do
    {:error, "expected a list of modern format atoms"}
  end

  defp format_order_error([], _modern_formats),
    do: {:error, "expected a non-empty list of modern formats"}

  defp format_order_error(order, modern_formats) do
    if Enum.all?(order, &(&1 in modern_formats)) do
      {:error, "expected distinct formats, got: #{inspect(order)}"}
    else
      {:error, "expected formats from #{inspect(modern_formats)}, got: #{inspect(order)}"}
    end
  end

  defp reject_unknown_opts!(opts) do
    case Enum.find(Keyword.keys(opts), &(&1 not in @known_option_keys)) do
      nil ->
        opts

      key ->
        raise ArgumentError, "unknown ImagePipe.Dialect.Native option #{inspect(key)}"
    end
  end

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.Dialect.Native options: #{Exception.message(error)}"
    end
  end

  defp reject_unimplemented_on_inert_option!(opts) do
    case Keyword.fetch(opts, :on_inert_option) do
      {:ok, :ignore} ->
        raise ArgumentError,
              "ImagePipe.Dialect.Native on_inert_option: :ignore is not yet implemented"

      _other ->
        opts
    end
  end
end
