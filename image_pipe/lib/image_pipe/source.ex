defmodule ImagePipe.Source do
  @moduledoc """
  Behaviour for source adapters.

  A source adapter validates its mount options, resolves canonical
  `ImagePipe.Plan.Source` values into a `ImagePipe.Source.Resolved` value, and
  fetches that value as an `ImagePipe.Source.Response`.

  Configure adapters as named mounts under `:sources`. Each mount names its
  adapter, the sources it serves, and the adapter's options:

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

  `:match` is `:path` (bare paths no prefix matches) or a keyword list of
  `:prefix` (a single leading path segment) and `:scheme` values, each a string
  or a list. `http`, `https`, and `s3` route URL and object sources; any other
  scheme is another spelling of a path prefix, so `asset://catalog/42` reaches
  its mount as the path `catalog/42`.

  Adapter callbacks receive their own validated options and a projected set
  of runtime limits. They never receive the complete mount configuration.
  """

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Error, ImagePipe.MaterialDigest, ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      CachePolicy,
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
  The kinds of plan source the adapter resolves: `:path` for
  `ImagePipe.Plan.Source.Path`, `:url` for `ImagePipe.Plan.Source.URL`, and
  `:object` for `ImagePipe.Plan.Source.Object`. A mount whose match rules would
  route another kind to the adapter fails configuration.
  """
  @callback source_kinds() :: [:path | :url | :object]
  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  @callback resolve(PlanSource.t(), keyword(), keyword()) ::
              {:ok, Resolved.t()} | {:error, error()}

  @doc """
  The third argument must be projected with `runtime_opts/1`. Passing the full
  mount configuration would expose other source and cache adapters' credentials.
  """
  @callback fetch(Resolved.t(), keyword(), keyword()) ::
              {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, error()}

  @source_kinds [:path, :url, :object, :input]
  @internal_cache_policies [:enabled, :disabled]
  @http_cache_policies [:inherit, :enabled, :disabled]

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

  @doc """
  Selects the runtime options passed as the third argument to `c:resolve/3`
  and `c:fetch/3`.

  Adapters receive their own validated options separately. This projection
  excludes `:sources` and `:cache`, which can contain other adapters' credentials.
  """
  @spec runtime_opts(keyword()) :: keyword()
  def runtime_opts(config) when is_list(config),
    do: Keyword.take(config, @runtime_option_keys)

  @doc "Freezes dynamic origin credentials before partitioning a cached request."
  def prepare_cache_context(source, config) do
    {:ok, module, opts} = mount_config(source, config)

    with {:ok, prepared} <- prepare_cache_source(module, source, opts, runtime_opts(config)) do
      # Cache and admission settings don't change fetched bytes. path_pattern
      # is also a compiled regex, which has no stable serialization.
      context =
        {module,
         Keyword.drop(opts, [:cache_policy, :stable, :internal_cache, :http_cache, :path_pattern]),
         prepared.fetch}

      identity =
        case prepared.cache_semantics.byte_identity do
          :none -> :none
          {:strong, seed} -> {:strong, {seed, ImagePipe.MaterialDigest.of(context)}}
        end

      {:ok, %{prepared | cache_semantics: %{prepared.cache_semantics | byte_identity: identity}},
       context}
    end
  rescue
    _exception -> {:error, {:source, :credentials_unavailable}}
  end

  defp prepare_cache_source(module, source, opts, runtime)
       when module in [ImagePipe.Source.HTTP, ImagePipe.Source.S3],
       do: module.prepare_cache(source, opts, runtime)

  defp prepare_cache_source(_module, source, _opts, _runtime), do: {:ok, source}

  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, error()}
  def validate_config(opts) when is_list(opts) do
    with {:ok, policy} <- CachePolicy.validate(Keyword.get(opts, :source_cache_policy, [])),
         {:ok, sources} <- Mounts.validate(Keyword.get(opts, :sources, [])) do
      {:ok, opts |> Keyword.put(:sources, sources) |> Keyword.put(:source_cache_policy, policy)}
    end
  end

  @spec validate_config!(keyword()) :: keyword()
  def validate_config!(opts) when is_list(opts) do
    case validate_config(opts) do
      {:ok, opts} ->
        opts

      {:error, reason} ->
        raise ArgumentError, "invalid ImagePipe source options: #{inspect(reason)}"
    end
  end

  @spec resolve(PlanSource.t() | Input.t(), keyword(), keyword()) ::
          {:ok, Resolved.t()} | {:error, error()}
  def resolve(%Input{} = source, _opts, runtime_opts),
    do: resolve_with(Input, [], nil, :input, source, runtime_opts, [])

  def resolve(source, opts, runtime_opts) do
    with {:ok, name, source_kind, source} <- Mounts.route(source, mounts(opts)),
         {:ok, module, adapter_opts} <- Mounts.fetch(mounts(opts), name) do
      resolve_with(
        module,
        adapter_opts,
        name,
        source_kind,
        source,
        runtime_opts,
        Keyword.get(opts, :source_cache_policy, [])
      )
    end
  end

  defp resolve_with(module, adapter_opts, name, source_kind, source, runtime_opts, policy) do
    source_metadata = source_metadata(source_kind, adapter_opts)
    telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

    Telemetry.span(telemetry_opts, [:source, :resolve], source_metadata, fn ->
      result =
        module
        |> run_resolve(source, adapter_opts, runtime_opts)
        |> put_mount(name)
        |> apply_cache_policy(policy)

      {result, result_metadata(result)}
    end)
  end

  defp mounts(opts), do: Keyword.get(opts, :sources, %Mounts{})

  # Mounts never share cache entries, even when their adapters build the same
  # identity for the path they receive.
  defp put_mount({:ok, resolved}, nil), do: {:ok, resolved}

  defp put_mount({:ok, resolved}, name),
    do: {:ok, %{resolved | mount: name, identity: resolved.identity ++ [mount: name]}}

  defp put_mount(error, _name), do: error

  defp mount_config(%Resolved{source_kind: :input}, _opts), do: {:ok, Input, []}
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

  @spec fetch(Resolved.t(), keyword(), keyword()) ::
          {:ok, Response.t()} | {:not_modified, Origin.t()} | {:error, error()}
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    with {:ok, module, adapter_opts} <- mount_config(resolved, opts) do
      source_metadata = source_metadata(resolved.source_kind, adapter_opts)

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

  @doc """
  Fetches a source and passes its `Response.t()` to `fun`.

  Uses `fetch/3`'s telemetry, body-size limit, and source-error normalization.
  `config` selects the adapter through `:sources`; `runtime_opts/1` selects
  the runtime options it receives.

  Resource streams clean up on completion, early halt, or reducer failure.
  The response's close function also runs when the callback exits, including
  when it never enumerates the body. Streams must be consumed in this process
  and within this bracket; this function never re-enumerates them.

  Returns `fun`'s result or `fetch/3`'s `{:error, {:source, _}}` unchanged.
  Exceptions and throws from `fun` propagate unchanged.
  """
  @spec with_fetched(Resolved.t(), keyword(), (Response.t() -> result)) ::
          result | {:error, error()}
        when result: var
  def with_fetched(%Resolved{} = resolved, config, fun) when is_function(fun, 1) do
    resolved |> fetch(config, runtime_opts(config)) |> consume(fun)
  end

  @doc """
  Revalidates prior origin evidence. A changed response is passed to `fun` in
  the same resource bracket as `with_fetched/3`. A valid upstream 304 returns
  `{:not_modified, refreshed_origin}` without invoking the body consumer.
  """
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
    resolved.source_kind in @source_kinds and
      resolved.internal_cache in @internal_cache_policies and
      resolved.http_cache in @http_cache_policies and
      valid_cache_semantics?(resolved.cache_semantics) and
      Identity.valid?(resolved.identity)
  end

  defp valid_cache_semantics?(%CacheSemantics{
         byte_identity: :none,
         stable?: false,
         policy: policy
       }),
       do: match?({:ok, _}, CachePolicy.validate(policy))

  defp valid_cache_semantics?(%CacheSemantics{
         byte_identity: {:strong, _seed},
         stable?: true,
         policy: policy
       }),
       do: match?({:ok, _}, CachePolicy.validate(policy))

  defp valid_cache_semantics?(_cache_semantics), do: false

  defp source_metadata(source_kind, adapter_opts) do
    %{
      source_kind: source_kind,
      source_adapter_kind: Keyword.get(adapter_opts, :telemetry_kind, :custom)
    }
  end

  defp result_metadata({:ok, _value}), do: %{result: :ok}
  defp result_metadata({:not_modified, _origin}), do: %{result: :not_modified}

  defp result_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}
end
