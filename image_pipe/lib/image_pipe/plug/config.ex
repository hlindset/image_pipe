defmodule ImagePipe.Plug.Config do
  # Validates and resolves the mount configuration.
  #
  # Mount-only parsing and delivery controls extend the shared host configuration
  # used by direct Elixir execution.
  @moduledoc false

  alias ImagePipe.Config, as: SharedConfig

  @options_schema NimbleOptions.new!(
                    allow_origin: [
                      type: {:custom, __MODULE__, :validate_allow_origin, []},
                      type_doc: "`t:String.t/0`",
                      doc: """
                      CORS origin sent in `Access-Control-Allow-Origin`, such as \
                      `"https://app.example.com"` or `"*"`. Scripts on that origin can read \
                      every response header, such as `ETag` and `Content-Disposition`, and \
                      send any request header except `Authorization`. Scripts can't read \
                      responses to requests sent with cookies. Without it, responses carry no \
                      CORS headers.
                      """
                    ],
                    allow_debug_headers: [
                      type: :boolean,
                      default: false,
                      doc: """
                      Lets a request's `debug` option add diagnostic headers to the response. \
                      See [debug headers](debug_headers.md).
                      """
                    ],
                    http_cache: [
                      type: {:in, [:validators, :auto, :public, :private]},
                      default: :validators,
                      doc: """
                      Which HTTP cache headers responses carry. See \
                      [HTTP cache headers](cdn-http-cache.md#header-modes).
                      """
                    ]
                  )

  @instance_schema NimbleOptions.new!(
                     instance: [
                       type: {:custom, __MODULE__, :validate_instance, []},
                       type_doc: "`t:atom/0`",
                       required: true,
                       doc: """
                       Name of a running instance (see `ImagePipe.child_spec/1`) whose \
                       configuration the mount serves.
                       """
                     ],
                     mount: [
                       type: :atom,
                       doc: """
                       Name of one of the instance's `:mounts`, whose URL options check \
                       request URLs. Defaults to the instance's own URL options.
                       """
                     ]
                   )

  @doc false
  def options_schema, do: @options_schema.schema

  @doc false
  def instance_schema, do: @instance_schema.schema

  @doc false
  @spec validate!(keyword() | SharedConfig.t()) ::
          keyword() | {:instance, atom(), atom() | nil, keyword()}
  def validate!(opts) when is_list(opts) do
    if Keyword.has_key?(opts, :instance),
      do: validate_instance!(opts),
      else: validate_inline!(opts)
  end

  def validate!(%SharedConfig{} = config), do: validate!(config: config)

  @doc false
  # Resolves a mount on a supervised instance for one request.
  @spec resolve({:instance, atom(), atom() | nil, keyword()}) :: keyword()
  def resolve({:instance, name, mount_name, mount}),
    do: Keyword.merge(mount, SharedConfig.fetch_instance!(name, mount_name).options)

  # Shared configuration belongs to the instance, so only mount-only options
  # and the name of one of the instance's named mounts are accepted.
  defp validate_instance!(opts) do
    {instance, opts} = Keyword.split(opts, [:instance, :mount])

    case NimbleOptions.validate(instance, @instance_schema) do
      {:ok, instance} ->
        {:instance, instance[:instance], instance[:mount], validate_known_opts!(opts)}

      {:error, error} ->
        raise ArgumentError, "invalid ImagePipe.Plug options: #{Exception.message(error)}"
    end
  end

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
  def validate_instance(name) when is_atom(name) and not is_nil(name), do: {:ok, name}

  def validate_instance(name),
    do: {:error, "expected the name of an instance, got: #{inspect(name)}"}

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
              "invalid ImagePipe.Plug options: #{Exception.message(error)}"
    end
  end
end
