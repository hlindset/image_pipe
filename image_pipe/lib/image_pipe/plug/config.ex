defmodule ImagePipe.Plug.Config do
  # Validates and resolves the mount configuration.
  #
  # Mount-only parsing and delivery controls extend the shared host configuration
  # used by direct Elixir execution.
  @moduledoc false

  alias ImagePipe.Config, as: SharedConfig

  @options_schema NimbleOptions.new!(
                    allow_origin: [
                      type: {:custom, __MODULE__, :validate_allow_origin, []}
                    ],
                    allow_debug_headers: [type: :boolean, default: false],
                    http_cache: [
                      type: {:in, [:validators, :auto, :public, :private]},
                      default: :validators
                    ]
                  )

  @doc false
  def options_schema, do: @options_schema.schema

  @doc false
  @spec validate!(keyword() | SharedConfig.t()) ::
          keyword() | {:instance, atom(), atom() | nil, keyword()}
  def validate!(opts) when is_list(opts) do
    case Keyword.pop(opts, :instance) do
      {nil, opts} -> validate_inline!(opts)
      {instance, opts} -> validate_instance!(instance, opts)
    end
  end

  def validate!(%SharedConfig{} = config), do: validate!(config: config)

  @doc false
  # Resolves a mount on a supervised instance for one request.
  @spec resolve({:instance, atom(), atom() | nil, keyword()}) :: keyword()
  def resolve({:instance, name, url, mount}),
    do: Keyword.merge(mount, SharedConfig.fetch_instance!(name, url).options)

  # Shared configuration belongs to the instance, so only mount-only options
  # and the name of one of the instance's URL configurations are accepted.
  defp validate_instance!(instance, opts) when is_atom(instance) do
    case Keyword.pop(opts, :url) do
      {url, opts} when is_atom(url) ->
        {:instance, instance, url, validate_known_opts!(opts)}

      {_url, _opts} ->
        raise ArgumentError,
              "invalid ImagePipe.API options: url must name one of the instance's urls"
    end
  end

  defp validate_instance!(_instance, _opts),
    do: raise(ArgumentError, "invalid ImagePipe.API options: instance must be an atom")

  defp validate_inline!(opts) do
    {shared, opts} = Keyword.pop(opts, :config)
    {mount, shared_options} = Keyword.split(opts, Keyword.keys(@options_schema.schema))

    config =
      shared
      |> shared_config(shared_options)
      |> SharedConfig.reject_unsupervised_processes!()

    mount
    |> validate_known_opts!()
    |> Keyword.merge(config.options)
  end

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
