defmodule ImagePipe.Plug.Config do
  @moduledoc """
  Validates and resolves the mount configuration.

  Mount-only parsing and delivery controls extend the shared host configuration
  used by direct Elixir execution.
  """

  alias ImagePipe.Config, as: SharedConfig

  @options_schema NimbleOptions.new!(
                    allow_origin: [
                      type: {:custom, __MODULE__, :validate_allow_origin, []}
                    ],
                    allow_debug_headers: [type: :boolean, default: false],
                    http_cache: [
                      type: :keyword_list,
                      keys: [
                        mode: [type: {:in, [:disabled, :enabled]}, default: :disabled],
                        visibility: [type: {:in, [:auto, :private, :public]}, default: :auto]
                      ]
                    ]
                  )

  @doc false
  @spec validate!(keyword() | SharedConfig.t()) :: keyword()
  def validate!(opts) when is_list(opts) do
    {shared, opts} = Keyword.pop(opts, :config)
    {mount, shared_options} = Keyword.split(opts, Keyword.keys(@options_schema.schema))
    config = shared_config(shared, shared_options)

    mount
    |> validate_known_opts!()
    |> Keyword.merge(config.options)
  end

  def validate!(%SharedConfig{} = config), do: validate!(config: config)

  defp shared_config(nil, options), do: SharedConfig.new!(options)

  defp shared_config(%SharedConfig{} = config, options),
    do: SharedConfig.override(config, options)

  defp shared_config(_invalid, _options),
    do: raise(ArgumentError, "config must be built with ImagePipe.config/1")

  @doc false
  def validate_allow_origin(value) when is_binary(value) and value != "" do
    if String.match?(value, ~r/[[:cntrl:]]/),
      do: {:error, "must not contain control characters"},
      else: {:ok, value}
  end

  def validate_allow_origin(""),
    do: {:error, "expected a non-empty string (omit allow_origin to disable CORS)"}

  def validate_allow_origin(_value), do: {:error, "expected a string"}

  defp validate_known_opts!(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated_opts} ->
        validated_opts

      {:error, %NimbleOptions.ValidationError{} = error} ->
        raise ArgumentError,
              "invalid ImagePipe.API options: #{Exception.message(error)}"
    end
  end
end
