defmodule ImagePipe.Source do
  @moduledoc """
  Behaviour for source adapters, and the shape of the `:sources` option of
  `ImagePipe.config/1`.

  ## Configuring sources

  `:sources` is a keyword list of sources. Each has a name, an adapter, the
  image paths it serves, and the adapter's options:

      sources: [
        media: [
          adapter: ImagePipe.Source.File,
          match: [prefix: "media"],
          options: [root: "/srv/images", root_id: "media"]
        ],
        web: [
          adapter: ImagePipe.Source.HTTP,
          match: [scheme: ["http", "https"]],
          options: [allowed_hosts: ["assets.example.com"]]
        ]
      ]

    * `:adapter` - `ImagePipe.Source.File`, `ImagePipe.Source.HTTP`,
      `ImagePipe.Source.S3`, or a module implementing this behaviour.
    * `:match` - which image paths reach the source: `:path`, or a keyword
      list of `:prefix` and `:scheme` rules. The rules are listed in
      [routing image paths to sources](sources.md#routing-image-paths-to-sources).
    * `:options` - the adapter's options, checked by its
      `c:validate_options/1`. The default value is `[]`.

  Building a configuration with an invalid source raises `ArgumentError`.
  The source's name appears in
  [telemetry events](telemetry-events.md#common-metadata) as `:source_mount`.

  ## Adapters

  An adapter's callbacks receive its own validated options and a set of
  runtime limits, never the rest of the configuration. Writing one is covered
  in [Writing a custom source](custom-sources.md).

  ## Errors

  An adapter fails a request by returning `{:error, {:source, reason}}`. Each
  reason below gives the listed status, as it does for the built-in adapters:

    * `:not_found` - `404`.
    * `{:bad_status, code}` - the origin's HTTP status. `401`, `403`, `404`,
      and `410` give `404`. Any other status gives `502`.
    * `:body_too_large` - `413`.
    * `:receive_timeout` - `504`.
    * `:unreadable` and `:credentials_unavailable` - `500`.

  Any other reason gives `502`. To choose the status, lead the reason with
  a class: `{:source, {class, detail}}`, where `class` is `:bad_request`
  (`400`), `:not_found` (`404`), `:payload_too_large` (`413`),
  `:unsupported_media` (`415`), `:server_error` (`500`), `:not_implemented`
  (`501`), `:bad_gateway` (`502`), or `:gateway_timeout` (`504`). The detail
  never reaches the response body. [Error responses](errors.md) lists every
  status.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Error, ImagePipe.MaterialDigest, ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      CachePolicy,
      CacheSettings,
      CacheState,
      CacheSemantics,
      Download,
      Origin,
      Record,
      Resolved,
      Response,
      Parser,
      StreamError,
      HTTP,
      File,
      S3,
      S3.RefreshCache,
      S3.CredentialProvider,
      S3.CredentialWarmup
    ]

  alias ImagePipe.Error
  alias ImagePipe.Plan.Source, as: PlanSource
  alias ImagePipe.Plan.Source.Identity
  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Input
  alias ImagePipe.Source.Mounts
  alias ImagePipe.Source.Origin
  alias ImagePipe.Source.Parser
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.WrappedStream
  alias ImagePipe.Telemetry

  @doc false
  def from_input(input, config), do: Input.prepare(input, config)

  @doc false
  defdelegate reduce_body(stream, accumulator, consumer), to: WrappedStream, as: :reduce

  @type error :: {:source, atom() | tuple()}

  @doc """
  Receives the options returned by `c:validate_options/1` and returns the
  identifier structs `c:resolve/3` accepts with them, from
  `ImagePipe.Plan.Source.Path`, `ImagePipe.Plan.Source.URL`, and
  `ImagePipe.Plan.Source.Object`. A source whose match rules would route another
  identifier to the adapter fails configuration.
  """
  @callback identifiers(options :: keyword()) :: [module()]

  @doc """
  Checks the source's `:options` when the configuration is built. The options
  it returns are passed to `c:resolve/3` and `c:fetch/3`. An error fails the
  configuration with `ArgumentError`.
  """
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}

  @doc """
  Describes an image without fetching it.

  The first argument is the requested image as one of the structs from
  `c:identifiers/1`, with the source's matching prefix or custom scheme
  removed. The returned `ImagePipe.Source.Resolved`
  holds:

    * `identity` - a keyword list that names the original, with atom keys
      and strings, numbers, booleans, `nil`, non-module atoms, or lists of
      them as values. It must include everything that selects different
      bytes, or two originals share cache entries.
    * `internal_cache`, `http_cache`, and `cache_semantics` - built with
      `ImagePipe.Source.CacheSettings.fields/2`.
    * `fetch` - any data `c:fetch/3` needs.

  The third argument holds runtime limits. Return
  `{:error, {:source, reason}}` for a source the adapter can't serve. The
  status each reason gives is listed under [errors](#module-errors). Any
  other return value fails the request with `500`.
  """
  @callback resolve(PlanSource.t(), keyword(), keyword()) ::
              {:ok, Resolved.t()} | {:error, error()}

  @doc """
  Fetches the original's bytes as an `ImagePipe.Source.Response`, with
  exactly one of `stream` or `path`. A stream is subject to the
  `:max_body_bytes` limit.

  The third argument holds runtime limits: `:max_body_bytes`, the transport
  timeouts, and the telemetry prefix. `{:not_modified, origin}` answers a
  revalidation of origin headers the adapter returned before.
  """
  @callback fetch(Resolved.t(), keyword(), keyword()) ::
              {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, error()}

  @internal_cache_policies [:enabled, :disabled]
  @http_cache_policies [:inherit, :validators, :auto, :public, :private]

  # Adapter runtime options: body limit, transport timeouts, and telemetry.
  # HTTP and S3 honor these timeout overrides when called directly; mount
  # configuration rejects them as unknown keys.
  @runtime_option_keys [
    :max_body_bytes,
    :receive_timeout,
    :connect_timeout,
    :pool_timeout,
    :clock,
    :telemetry_prefix
  ]

  # Selects the runtime options passed as the third argument to `c:resolve/3`
  # and `c:fetch/3`.
  #
  # Adapters receive their own validated options separately. This projection
  # excludes `:sources` and `:cache`, which can contain other adapters' credentials.
  @doc false
  @spec runtime_opts(keyword()) :: keyword()
  def runtime_opts(config) when is_list(config),
    do: Keyword.take(config, @runtime_option_keys)

  # An immutable HTTP or S3 original changes when the adapter's settings do,
  # such as its bucket or base URL, so those settings join the original's
  # version. Other adapters identify an immutable original by their identity
  # seed alone, whether or not it is copied.
  @settings_versioned [ImagePipe.Source.HTTP, ImagePipe.Source.S3]

  # Freezes dynamic origin credentials before partitioning a cached request.
  @doc false
  def prepare_cache_context(source, config) do
    {:ok, module, opts} = mount_config(source, config)

    with {:ok, prepared} <- prepare_cache_source(module, source, opts, runtime_opts(config)) do
      # Cache and admission settings don't change fetched bytes. path_pattern
      # is also a compiled regex, which has no stable serialization.
      context =
        {module,
         Keyword.drop(
           opts,
           [:cache_policy, :stable, :internal_cache, :http_cache, :path_pattern, :verify, :copy] ++
             location_options(module)
         ), prepared.fetch}

      identity =
        case prepared.cache_semantics.byte_identity do
          {:strong, seed} when module in @settings_versioned ->
            {:strong, {seed, ImagePipe.MaterialDigest.of(context)}}

          identity ->
            identity
        end

      {:ok, %{prepared | cache_semantics: %{prepared.cache_semantics | byte_identity: identity}},
       context}
    end
  rescue
    _exception -> {:error, {:source, :credentials_unavailable}}
  end

  # A File source's `root_id` names its directory, so moving the directory to a
  # new `root` keeps its cached originals and results.
  defp location_options(ImagePipe.Source.File), do: [:root]
  defp location_options(_module), do: []

  defp prepare_cache_source(module, source, opts, runtime)
       when module in [ImagePipe.Source.HTTP, ImagePipe.Source.S3],
       do: module.prepare_cache(source, opts, runtime)

  defp prepare_cache_source(_module, source, _opts, _runtime), do: {:ok, source}

  @doc false
  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, error() | String.t()}
  def validate_config(opts) when is_list(opts) do
    with {:ok, policy} <- CachePolicy.validate(Keyword.get(opts, :source_cache_policy, [])),
         {:ok, sources} <- Mounts.validate(Keyword.get(opts, :sources, [])) do
      {:ok, opts |> Keyword.put(:sources, sources) |> Keyword.put(:source_cache_policy, policy)}
    end
  end

  @doc false
  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} ->
        opts

      {:error, reason} ->
        raise ArgumentError, config_error_message(reason)
    end
  end

  defp config_error_message({:source, {:invalid_source, name, message}}),
    do: "invalid source #{inspect(name)}: #{message}"

  defp config_error_message({:source, {:invalid_sources, message}}),
    do: "invalid sources: #{message}"

  defp config_error_message(message) when is_binary(message),
    do: "invalid source_cache_policy: #{message}"

  # Translates a host-configured source string into a plan source that a
  # configured mount serves. `opts` holds validated mounts.
  @doc false
  @spec translate_configured(String.t(), keyword()) :: {:ok, PlanSource.t()} | {:error, term()}
  def translate_configured(source, opts) when is_binary(source) do
    with {:ok, plan_source} <- Parser.translate(source, opts),
         {:ok, _name, _source} <- Mounts.route(plan_source, mounts(opts)) do
      {:ok, plan_source}
    end
  end

  @doc false
  @spec resolve(PlanSource.t() | Input.t(), keyword(), keyword()) ::
          {:ok, Resolved.t()} | {:error, error()}
  def resolve(%Input{} = source, _opts, runtime_opts),
    do: resolve_with(Input, [], nil, source, runtime_opts, [])

  def resolve(source, opts, runtime_opts) do
    with {:ok, name, source} <- Mounts.route(source, mounts(opts)),
         {:ok, module, adapter_opts} <- Mounts.fetch(mounts(opts), name) do
      resolve_with(
        module,
        adapter_opts,
        name,
        source,
        runtime_opts,
        Keyword.get(opts, :source_cache_policy, [])
      )
    end
  end

  defp resolve_with(module, adapter_opts, name, source, runtime_opts, policy) do
    source_metadata = %{source_mount: name}
    telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

    Telemetry.span(telemetry_opts, [:source, :resolve], source_metadata, fn ->
      result =
        module
        |> run_resolve(source, adapter_opts, runtime_opts)
        |> put_mount(name, module, adapter_opts)
        |> apply_cache_policy(policy)

      {result, result_metadata(result)}
    end)
  end

  defp mounts(opts), do: Keyword.get(opts, :sources, %Mounts{})

  # Sources that read the same originals share cache entries, so a source's
  # name stays out of the identity. Built-in adapters name every setting that
  # changes bytes in their identity or byte identity. A custom adapter's
  # identity may not, so a digest of its options, apart from the cache
  # settings, keeps two differently configured sources apart.
  @builtin_adapters [ImagePipe.Source.File, ImagePipe.Source.HTTP, ImagePipe.Source.S3]
  @cache_setting_keys Keyword.keys(ImagePipe.Source.CacheSettings.schema())

  defp put_mount({:ok, resolved}, nil, _module, _opts), do: {:ok, resolved}

  defp put_mount({:ok, resolved}, name, module, opts),
    do:
      {:ok,
       %{resolved | mount: name, identity: resolved.identity ++ adapter_identity(module, opts)}}

  defp put_mount(error, _name, _module, _opts), do: error

  defp adapter_identity(module, _opts) when module in @builtin_adapters, do: [source: module]

  defp adapter_identity(module, opts) do
    digest =
      opts
      |> Keyword.drop(@cache_setting_keys)
      |> stable_terms()
      |> ImagePipe.MaterialDigest.of()

    [source: module, options: Base.encode16(digest, case: :lower)]
  end

  # A compiled regex serializes differently each time it is compiled.
  defp stable_terms(%Regex{} = regex), do: {Regex, Regex.source(regex), Regex.opts(regex)}
  defp stable_terms(list) when is_list(list), do: Enum.map(list, &stable_terms/1)

  defp stable_terms(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> stable_terms() |> List.to_tuple()

  defp stable_terms(%module{} = struct),
    do: struct(module, struct |> Map.from_struct() |> stable_terms())

  defp stable_terms(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, stable_terms(v)} end)
  defp stable_terms(term), do: term

  defp mount_config(%Resolved{mount: nil}, _opts), do: {:ok, Input, []}
  defp mount_config(%Resolved{mount: name}, opts), do: Mounts.fetch(mounts(opts), name)

  defp apply_cache_policy({:ok, resolved}, defaults) do
    semantics = resolved.cache_semantics
    policy = CachePolicy.merge(defaults, semantics.policy)

    internal_cache =
      case Keyword.get(policy, :storage, :origin) do
        :deny -> :disabled
        _permission -> resolved.internal_cache
      end

    {:ok,
     %{resolved | cache_semantics: %{semantics | policy: policy}, internal_cache: internal_cache}}
  end

  defp apply_cache_policy({:error, _reason} = error, _defaults), do: error

  defp run_resolve(module, source, adapter_opts, runtime_opts) do
    case module.resolve(source, adapter_opts, runtime_opts) do
      {:ok, %Resolved{} = resolved} -> validate_resolved(resolved)
      {:error, {:source, _reason}} = error -> error
      _other -> {:error, {:source, :invalid_adapter_result}}
    end
  end

  @doc false
  @spec fetch(Resolved.t(), keyword(), keyword()) ::
          {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, error()}
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    with {:ok, module, adapter_opts} <- mount_config(resolved, opts) do
      source_metadata = %{source_mount: resolved.mount}

      telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

      Telemetry.span(telemetry_opts, [:source, :fetch], source_metadata, fn ->
        result = run_fetch(module, resolved, adapter_opts, runtime_opts)
        {result, result_metadata(result)}
      end)
    end
  end

  defp run_fetch(module, resolved, adapter_opts, runtime_opts) do
    case module.fetch(resolved, adapter_opts, runtime_opts) do
      {:ok, %Response{} = response} -> wrap_response(response, runtime_opts)
      {:not_modified, %Origin{} = origin} -> validated_not_modified(origin, runtime_opts)
      {:error, {:source, _reason}} = error -> error
      _other -> {:error, {:source, :invalid_adapter_result}}
    end
  end

  defp validated_not_modified(origin, runtime_opts) do
    case Keyword.get(runtime_opts, :source_validation) do
      %Origin{} ->
        case Origin.valid?(origin) do
          true -> {:not_modified, origin}
          false -> {:error, {:source, :invalid_adapter_result}}
        end

      nil ->
        {:error, {:source, :unexpected_not_modified}}
    end
  end

  # Fetches a source and passes its `Response.t()` to `fun`.
  #
  # Uses `fetch/3`'s telemetry, body-size limit, and source-error normalization.
  # `config` selects the adapter through `:sources`; `runtime_opts/1` selects
  # the runtime options it receives.
  #
  # Resource streams clean up on completion, early halt, or reducer failure.
  # The response's close function also runs when the callback exits, including
  # when it never enumerates the body. Streams must be consumed in this process
  # and within this bracket; this function never re-enumerates them.
  #
  # Returns `fun`'s result or `fetch/3`'s `{:error, {:source, _}}` unchanged.
  # Exceptions and throws from `fun` propagate unchanged.
  @doc false
  @spec with_fetched(Resolved.t(), keyword(), (Response.t() -> result)) ::
          result | {:error, error()}
        when result: var
  def with_fetched(%Resolved{} = resolved, config, fun) when is_function(fun, 1) do
    resolved |> fetch(config, runtime_opts(config)) |> consume(fun)
  end

  # Revalidates prior origin evidence. A changed response is passed to `fun` in
  # the same resource bracket as `with_fetched/3`. A valid upstream 304 returns
  # `{:not_modified, refreshed_origin}` without invoking the body consumer.
  @doc false
  def with_revalidated(%Resolved{} = resolved, %Origin{} = previous, config, fun) do
    runtime = Keyword.put(runtime_opts(config), :source_validation, previous)
    resolved |> fetch(config, runtime) |> consume(fun)
  end

  defp consume({:ok, response}, fun) do
    fun.(response)
  after
    Response.close(response)
  end

  defp consume({:not_modified, _origin} = result, _fun), do: result
  defp consume({:error, {:source, _reason}} = error, _fun), do: error

  @doc false
  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{} = response, runtime_opts) do
    valid_close? = is_nil(response.close) or is_function(response.close, 0)
    valid_origin? = is_nil(response.origin) or Origin.valid?(response.origin)

    case valid_close? and valid_origin? do
      true ->
        wrap_body(response, runtime_opts)

      false ->
        if valid_close?, do: Response.close(response)
        {:error, {:source, :invalid_adapter_result}}
    end
  end

  defp wrap_body(%Response{path: path, stream: nil} = response, _runtime_opts)
       when is_binary(path) do
    {:ok, response}
  end

  defp wrap_body(%Response{path: nil, stream: stream} = response, runtime_opts)
       when not is_nil(stream) do
    max_body_bytes = Keyword.fetch!(runtime_opts, :max_body_bytes)
    {:ok, %Response{response | stream: WrappedStream.new(stream, max_body_bytes)}}
  end

  # Host adapters must return exactly one of `path` or `stream`; accepting both
  # would let the path bypass the stream body limit.
  defp wrap_body(response, _runtime_opts) do
    Response.close(response)
    {:error, {:source, :invalid_adapter_result}}
  end

  defp validate_resolved(%Resolved{} = resolved) do
    if valid_resolved?(resolved),
      do: {:ok, resolved},
      else: {:error, {:source, :invalid_adapter_result}}
  end

  defp valid_resolved?(%Resolved{} = resolved) do
    resolved.internal_cache in @internal_cache_policies and
      resolved.http_cache in @http_cache_policies and
      valid_cache_semantics?(resolved.cache_semantics) and
      Identity.valid?(resolved.identity)
  end

  defp valid_cache_semantics?(%CacheSemantics{
         byte_identity: :content,
         stable?: false,
         policy: policy,
         copy?: copy?
       })
       when is_boolean(copy?),
       do: match?({:ok, _}, CachePolicy.validate(policy))

  defp valid_cache_semantics?(%CacheSemantics{
         byte_identity: {:strong, _seed},
         stable?: true,
         policy: policy,
         copy?: copy?
       })
       when is_boolean(copy?),
       do: match?({:ok, _}, CachePolicy.validate(policy))

  defp valid_cache_semantics?(_cache_semantics), do: false

  defp result_metadata({:ok, _value}), do: %{result: :ok}
  defp result_metadata({:not_modified, _origin}), do: %{result: :not_modified}

  defp result_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}
end
