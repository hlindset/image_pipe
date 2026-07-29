defmodule ImagePipe.Source do
  @moduledoc false

  use Boundary,
    top_level?: true,
    deps: [ImagePipe.Error, ImagePipe.Plan, ImagePipe.Telemetry],
    exports: [
      CacheSemantics,
      Resolved,
      Response,
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
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.WrappedStream
  alias ImagePipe.Telemetry

  @type error :: {:source, atom() | tuple()}

  @callback validate_options(keyword()) :: {:ok, keyword()} | {:error, term()}
  @callback resolve(PlanSource.t(), keyword(), keyword()) ::
              {:ok, Resolved.t()} | {:error, error()}

  @doc """
  The third argument (`runtime_opts`) must be a `runtime_opts/1`-projected
  keyword list, never a raw mount configuration — a mount configuration also
  holds every other source's adapter configuration and the cache adapter's
  configuration, both of which routinely carry credentials, and handing it
  to an adapter whole would leak them.
  """
  @callback fetch(Resolved.t(), keyword(), keyword()) :: {:ok, Response.t()} | {:error, error()}

  @source_kinds [:path, :url, :object, :reference]
  @internal_cache_policies [:enabled, :disabled]
  @http_cache_policies [:inherit, :enabled, :disabled]

  # The per-request runtime surface a source adapter may read: the body limit
  # it must honor, the transport timeouts it may override per request, and
  # the telemetry data it propagates.
  #
  # `:receive_timeout`, `:connect_timeout`, and `:pool_timeout` are honored
  # today by the HTTP and S3 adapters as per-request transport overrides
  # (`ImagePipe.Source.HTTP`, `ImagePipe.Source.S3`), even though no host
  # mount surface currently exposes them for configuration (host mount
  # configs validate against a closed key set and reject unknown keys). They
  # stay on this list as a deliberate contract for the adapter callback, not
  # because a mount can supply them yet.
  @runtime_option_keys [
    :max_body_bytes,
    :receive_timeout,
    :connect_timeout,
    :pool_timeout,
    :telemetry_prefix
  ]

  @doc """
  Projects a mount configuration down to the runtime options a source adapter
  may read (the third argument of `c:resolve/3` and `c:fetch/3`).

  An adapter already receives its own validated adapter options as the second
  argument; the third carries per-request runtime data only. A mount
  configuration additionally holds every *other* source's adapter
  configuration (`:sources`) and the cache adapter's configuration
  (`:cache`) — both of which routinely carry credentials — so it is never
  handed to an adapter whole.
  """
  @spec runtime_opts(keyword()) :: keyword()
  def runtime_opts(config) when is_list(config),
    do: Keyword.take(config, @runtime_option_keys)

  @spec validate_config(keyword()) :: {:ok, keyword()} | {:error, error()}
  def validate_config(opts) when is_list(opts) do
    with {:ok, sources} <- validate_sources(Keyword.get(opts, :sources, [])) do
      {:ok, Keyword.put(opts, :sources, sources)}
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

  @spec resolve(PlanSource.t(), keyword(), keyword()) :: {:ok, Resolved.t()} | {:error, error()}
  def resolve(source, opts, runtime_opts) do
    with {:ok, adapter, source_kind} <- source_route(source),
         {:ok, module, adapter_opts} <- fetch_adapter_config(adapter, opts) do
      source_metadata = source_metadata(source_kind, adapter_opts)

      telemetry_opts = Telemetry.telemetry_opts(runtime_opts)

      Telemetry.span(telemetry_opts, [:source, :resolve], source_metadata, fn ->
        result = run_resolve(module, source, adapter_opts, runtime_opts, adapter)
        {result, result_metadata(result)}
      end)
    end
  end

  defp run_resolve(module, source, adapter_opts, runtime_opts, adapter) do
    case module.resolve(source, adapter_opts, runtime_opts) do
      {:ok, %Resolved{} = resolved} -> validate_resolved(resolved, adapter)
      {:error, {:source, _reason}} = error -> error
      _other -> {:error, {:source, :invalid_adapter_result}}
    end
  end

  @spec fetch(Resolved.t(), keyword(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def fetch(%Resolved{} = resolved, opts, runtime_opts) do
    with {:ok, module, adapter_opts} <- fetch_adapter_config(resolved.adapter, opts) do
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
      {:error, {:source, _reason}} = error -> error
      _other -> {:error, {:source, :invalid_adapter_result}}
    end
  end

  @doc """
  Fetch bracket: resolves through `fetch/3` (its `[:source, :fetch]` span,
  `wrap_response/2` body-size limiting, and `{:source, _}` error
  normalization already apply there), then hands the response to `fun`.

  `config` is the mount configuration — it selects the adapter through
  `:sources`, and the adapter's runtime options are projected from it with
  `runtime_opts/1` rather than passed whole.

  `fun` receives the `Response.t()` directly. There is no separate close
  step here because closing is not this bracket's job to invent: when
  `fetch/3` returns a stream response, that stream is a lazy `Enumerable`
  built on `Stream.resource/3` (by the host adapter, then wrapped by
  `wrap_response/2`'s `WrappedStream`), and `Stream.resource/3` already
  guarantees its own cleanup function runs on any termination of
  enumeration it starts — normal completion, an early halt, or an
  exception propagating out of the reducer. A caller that fully drains the
  stream before doing further work (as `ImagePipe.Decode.with_image/4`
  does) therefore never leaves a live resource behind on any later error
  path. This bracket does not itself re-drain or otherwise touch
  `response.stream`: a `Stream` is re-entrant, so touching it a second time
  would reopen — and re-fetch — the same resource rather than reuse it.

  If `fun` raises or throws, the exception/throw propagates unchanged: this
  bracket normalizes only `fetch/3`'s own `{:error, {:source, _}}` return,
  never a caller exception.
  """
  @spec with_fetched(Resolved.t(), keyword(), (Response.t() -> result)) ::
          result | {:error, error()}
        when result: var
  def with_fetched(%Resolved{} = resolved, config, fun) when is_function(fun, 1) do
    case fetch(resolved, config, runtime_opts(config)) do
      {:ok, %Response{} = response} -> fun.(response)
      {:error, {:source, _reason}} = error -> error
    end
  end

  @spec wrap_response(Response.t(), keyword()) :: {:ok, Response.t()} | {:error, error()}
  def wrap_response(%Response{path: path, stream: nil} = response, _runtime_opts)
      when is_binary(path) do
    {:ok, response}
  end

  def wrap_response(%Response{path: nil, stream: stream} = response, runtime_opts)
      when not is_nil(stream) do
    max_body_bytes = Keyword.fetch!(runtime_opts, :max_body_bytes)
    {:ok, %Response{response | stream: WrappedStream.new(stream, max_body_bytes)}}
  end

  # A `Response` from a host-implementable `Source` adapter must carry exactly one of `path`
  # or `stream`. Both-set (which would let a path bypass the stream body-limit) and all-nil
  # are rejected at this boundary rather than trusted.
  def wrap_response(_response, _runtime_opts), do: {:error, {:source, :invalid_adapter_result}}

  defp validate_sources(sources) when is_list(sources) do
    with {:ok, source_configs} <- source_configs(sources) do
      {:ok, expand_url_source_config(source_configs)}
    end
  end

  defp validate_sources(_sources), do: {:error, {:source, :invalid_adapter_config}}

  defp source_configs(sources) do
    Enum.reduce_while(sources, {:ok, %{}}, fn entry, {:ok, source_configs} ->
      case source_config(entry) do
        {:ok, adapter, config} -> {:cont, {:ok, Map.put(source_configs, adapter, config)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp source_config({adapter, {module, adapter_opts}})
       when is_atom(adapter) and is_atom(module) and is_list(adapter_opts) do
    case module.validate_options(adapter_opts) do
      {:ok, validated_opts} when is_list(validated_opts) ->
        config = {module, order_validated_options(adapter_opts, validated_opts)}
        {:ok, adapter, config}

      {:error, {:source, _reason}} = error ->
        error

      {:error, reason} ->
        {:error, {:source, reason}}

      _other ->
        {:error, {:source, :invalid_adapter_config}}
    end
  end

  defp source_config(_entry), do: {:error, {:source, :invalid_adapter_config}}

  defp expand_url_source_config(%{url: url_config} = source_configs) do
    source_configs
    |> Map.delete(:url)
    |> Map.put_new(:http, url_config)
    |> Map.put_new(:https, url_config)
  end

  defp expand_url_source_config(source_configs), do: source_configs

  defp order_validated_options(input_opts, validated_opts) do
    input_keys = Keyword.keys(input_opts)

    ordered_input_values =
      Enum.flat_map(input_keys, fn key ->
        case Keyword.fetch(validated_opts, key) do
          {:ok, value} -> [{key, value}]
          :error -> []
        end
      end)

    extra_values =
      Enum.reject(validated_opts, fn {key, _value} ->
        key in input_keys
      end)

    ordered_input_values ++ extra_values
  end

  defp source_route(%PlanSource.Path{}), do: {:ok, :path, :path}
  defp source_route(%PlanSource.URL{scheme: :http}), do: {:ok, :http, :url}
  defp source_route(%PlanSource.URL{scheme: :https}), do: {:ok, :https, :url}

  defp source_route(%PlanSource.Object{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :object}

  defp source_route(%PlanSource.Reference{adapter: adapter}) when is_atom(adapter),
    do: {:ok, adapter, :reference}

  defp source_route(_source), do: {:error, {:source, :missing_adapter}}

  defp fetch_adapter_config(adapter, opts) do
    case opts[:sources] do
      %{^adapter => {module, adapter_opts}} -> {:ok, module, adapter_opts}
      _sources -> {:error, {:source, :missing_adapter}}
    end
  end

  defp validate_resolved(%Resolved{adapter: adapter} = resolved, adapter) do
    if valid_resolved?(resolved),
      do: {:ok, resolved},
      else: {:error, {:source, :invalid_adapter_result}}
  end

  defp validate_resolved(%Resolved{}, _adapter), do: {:error, {:source, :invalid_adapter_result}}

  defp valid_resolved?(%Resolved{} = resolved) do
    resolved.source_kind in @source_kinds and
      resolved.internal_cache in @internal_cache_policies and
      resolved.http_cache in @http_cache_policies and
      valid_cache_semantics?(resolved.cache_semantics) and
      Identity.valid?(resolved.identity)
  end

  defp valid_cache_semantics?(%CacheSemantics{byte_identity: :none, stable?: false}), do: true

  defp valid_cache_semantics?(%CacheSemantics{
         byte_identity: {:strong, _seed},
         stable?: true
       }),
       do: true

  defp valid_cache_semantics?(_cache_semantics), do: false

  defp source_metadata(source_kind, adapter_opts) do
    %{
      source_kind: source_kind,
      source_adapter_kind: Keyword.get(adapter_opts, :telemetry_kind, :custom)
    }
  end

  defp result_metadata({:ok, _value}), do: %{result: :ok}

  defp result_metadata({:error, {:source, error}}),
    do: %{result: :source_error, error: Error.tag(error)}
end
