defmodule ImagePipe.Dialect.SharedConfig do
  @moduledoc """
  Shared runtime option keys and validation for dialect config modules — a
  core boundary that happens to live under the `Dialect` namespace, not a
  product dialect itself.

  `keys/0` names the runtime option keys every dialect shares (source
  fetching, caching, request-safety limits, output negotiation defaults);
  `validate_runtime!/1` validates and defaults them, delegating `:cache`
  and `:sources` to their own boundaries. A calling dialect's config module
  splits its options on `keys/0`, validates the shared subset here, and
  validates its own dialect-specific keys itself.

  Shared-key validation failures raise against this module's own option
  surface ("invalid ImagePipe shared runtime options: …"), not the calling
  dialect's — every dialect reports one identical message for a bad shared
  key, and its own message only for its own keys.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Format,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    exports: []

  alias ImagePipe.Cache
  alias ImagePipe.Format
  alias ImagePipe.Source
  alias ImagePipe.Telemetry

  @default_max_body_bytes 10_000_000
  @default_max_input_pixels 40_000_000

  @keys [
    :cache,
    :sources,
    :max_body_bytes,
    :max_input_pixels,
    :telemetry_prefix,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl,
    :format_order,
    :output_capabilities,
    :max_result_width,
    :max_result_height,
    :max_result_pixels
  ]

  @validated_option_keys [
    :max_body_bytes,
    :max_input_pixels,
    :telemetry_prefix,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl,
    :format_order,
    :output_capabilities,
    :max_result_width,
    :max_result_height,
    :max_result_pixels
  ]

  @options_schema NimbleOptions.new!(
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
                    ],
                    output_capabilities: [
                      type: {:map, :atom, :boolean},
                      required: false
                    ],
                    max_result_width: [
                      type: :pos_integer,
                      default: 8_192
                    ],
                    max_result_height: [
                      type: :pos_integer,
                      default: 8_192
                    ],
                    max_result_pixels: [
                      type: :pos_integer,
                      default: 40_000_000
                    ]
                  )

  @doc "The shared runtime option keys every dialect config module delegates here."
  @spec keys() :: [atom()]
  def keys, do: @keys

  @doc """
  Validates one `storage_inputs` entry: `{:header, name}` or `{:cookie,
  name}` with a non-empty string name. Not itself one of `keys/0` — dialects
  that support configured storage-vary inputs (`ImagePipe.Representation.
  storage_inputs/2`) reference this from their own `storage_inputs:` schema
  entry, since which dialects expose the option (and its default) is a
  per-dialect config-surface choice, not a shared runtime default.
  """
  @spec validate_storage_input(term()) ::
          {:ok, {:header, String.t()} | {:cookie, String.t()}} | {:error, String.t()}
  def validate_storage_input({:header, name}) when is_binary(name) and name != "",
    do: {:ok, {:header, name}}

  def validate_storage_input({:cookie, name}) when is_binary(name) and name != "",
    do: {:ok, {:cookie, name}}

  def validate_storage_input(value),
    do:
      {:error,
       "expected {:header, name} or {:cookie, name} with a non-empty string name, got: #{inspect(value)}"}

  @doc """
  Validates and defaults the shared runtime keys, delegating `:cache` to
  `ImagePipe.Cache.validate_config!/1` and `:sources` to
  `ImagePipe.Source.validate_config!/1`. Raises `ArgumentError` on invalid
  input.
  """
  @spec validate_runtime!(keyword()) :: keyword()
  def validate_runtime!(opts) when is_list(opts) do
    opts
    |> Cache.validate_config!()
    |> Source.validate_config!()
    |> validate_known_opts!()
  end

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

  defp validate_known_opts!(opts) do
    known_opts = Keyword.take(opts, @validated_option_keys)

    case NimbleOptions.validate(known_opts, @options_schema) do
      {:ok, validated_opts} ->
        Keyword.merge(opts, validated_opts)

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe shared runtime options: #{Exception.message(error)}"
    end
  end
end
