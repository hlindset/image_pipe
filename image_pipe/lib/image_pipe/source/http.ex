defmodule ImagePipe.Source.HTTP do
  @moduledoc """
  Built-in HTTP source adapter with destination and response-size controls.

  `:allowed_hosts` is required unless `:base_url` is set. Redirects are disabled
  by default and every redirect target is checked against the same host and
  network-address policy. The default transport connects to validated addresses
  while preserving the original hostname for HTTP and TLS.
  Transport settings may be supplied through the documented timeout and
  `:req_options` fields in the mount configuration.

  Mounted under `path:` with `:base_url`, the adapter serves path sources from
  that origin: each path segment is percent-encoded and appended to the base
  URL, which then resolves exactly like a direct request for the full URL.
  `:allowed_hosts` defaults to the base URL's host. Paths with empty, `.`, or
  `..` segments are rejected, and an optional `:path_pattern` regex must match
  the whole relative path (segments joined with `/`).
  """

  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.Auth
  alias ImagePipe.Source.CacheSettings
  alias ImagePipe.Source.HTTP.AddressPolicy
  alias ImagePipe.Source.HTTP.TargetGuard
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.Resolved

  @internal_option_keys [
    :url,
    :base_url,
    :method,
    :body,
    :params,
    :into,
    :retry,
    :redirect,
    :max_redirects,
    :address_policy,
    :address_resolver
  ]
  @host_header_names ["host"]
  @default_ports %{http: 80, https: 443}
  @base_url_schemes %{"http" => :http, "https" => :https}

  @options_schema NimbleOptions.new!(
                    [
                      allowed_hosts: [type: {:list, :string}],
                      base_url: [type: :string],
                      path_pattern: [type: {:struct, Regex}],
                      req_options: [type: :keyword_list, default: []],
                      receive_timeout: [type: :non_neg_integer],
                      connect_timeout: [type: :non_neg_integer],
                      pool_timeout: [type: :non_neg_integer],
                      max_redirects: [type: :non_neg_integer, default: 0],
                      address_policy: [
                        type:
                          {:or,
                           [{:fun, 2}, {:custom, __MODULE__, :validate_address_policy_kw, []}]},
                        default: []
                      ],
                      address_resolver: [type: {:fun, 1}]
                    ] ++ CacheSettings.schema()
                  )

  @impl Source
  def source_kinds, do: [:path, :url]

  @impl Source
  def validate_options(opts) do
    with {:ok, validated} <- validate_schema(opts),
         {:ok, validated} <- validate_base_url(validated) do
      validated
      |> Keyword.update!(:allowed_hosts, fn hosts -> Enum.map(hosts, &String.downcase/1) end)
      |> Keyword.put(:telemetry_kind, :http)
      |> CacheSettings.validate()
    end
  end

  defp validate_schema(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  defp validate_base_url(opts) do
    case Keyword.fetch(opts, :base_url) do
      :error ->
        cond do
          not Keyword.has_key?(opts, :allowed_hosts) ->
            {:error, {:invalid_source_config, "required :allowed_hosts option not found"}}

          Keyword.has_key?(opts, :path_pattern) ->
            {:error, {:invalid_source_config, "path_pattern requires base_url"}}

          true ->
            {:ok, opts}
        end

      {:ok, base_url} ->
        with {:ok, base} <- parse_base_url(base_url),
             {:ok, hosts} <- base_allowed_hosts(opts, base.host),
             {:ok, opts} <- anchor_path_pattern(opts) do
          {:ok, opts |> Keyword.put(:base_url, base) |> Keyword.put(:allowed_hosts, hosts)}
        end
    end
  end

  # path_pattern must match the whole path, so anchor it once here.
  defp anchor_path_pattern(opts) do
    case Keyword.fetch(opts, :path_pattern) do
      :error ->
        {:ok, opts}

      {:ok, pattern} ->
        options = Regex.opts(pattern)
        close = if :extended in options, do: "\n)\\z", else: ")\\z"

        case Regex.compile("\\A(?:" <> Regex.source(pattern) <> close, options) do
          {:ok, anchored} -> {:ok, Keyword.put(opts, :path_pattern, anchored)}
          {:error, _reason} -> {:error, {:invalid_source_config, "invalid path_pattern"}}
        end
    end
  end

  defp parse_base_url(base_url) do
    with {:ok, %URI{scheme: scheme, host: host} = uri} when is_map_key(@base_url_schemes, scheme) <-
           URI.new(base_url),
         true <- is_binary(host) and host != "",
         true <- is_nil(uri.query) and is_nil(uri.fragment) and is_nil(uri.userinfo) do
      segments =
        uri.path |> Kernel.||("") |> String.split("/", trim: true) |> Enum.map(&URI.decode/1)

      {:ok,
       %{
         scheme: Map.fetch!(@base_url_schemes, scheme),
         host: String.downcase(host),
         port: uri.port,
         path: segments
       }}
    else
      _invalid ->
        {:error,
         {:invalid_source_config,
          "base_url must be an http(s) URL with a host and no query, fragment, or credentials"}}
    end
  end

  defp base_allowed_hosts(opts, base_host) do
    hosts = opts |> Keyword.get(:allowed_hosts, [base_host]) |> Enum.map(&String.downcase/1)

    if base_host in hosts,
      do: {:ok, hosts},
      else: {:error, {:invalid_source_config, "allowed_hosts must include the base_url host"}}
  end

  @doc false
  def validate_address_policy_kw(value) when is_list(value) do
    allowed_keys = [
      :allow_loopback,
      :allow_unspecified,
      :allow_link_local,
      :allow_private,
      :allow_unique_local,
      :allow_multicast,
      :allow_broadcast,
      :allow_cgnat,
      :allow_reserved,
      :allow
    ]

    cond do
      not Keyword.keyword?(value) ->
        {:error, "address_policy keyword list expected"}

      Enum.any?(Keyword.keys(value), &(&1 not in allowed_keys)) ->
        {:error, "unknown address_policy key"}

      Enum.any?(value, fn {key, setting} -> key != :allow and not is_boolean(setting) end) ->
        {:error, "address_policy category toggles must be booleans"}

      not is_list(Keyword.get(value, :allow, [])) ->
        {:error, "address_policy :allow must be a list of CIDR strings"}

      Enum.any?(Keyword.get(value, :allow, []), &(AddressPolicy.parse_cidr(&1) == :error)) ->
        {:error, "invalid CIDR in address_policy :allow"}

      true ->
        {:ok, value}
    end
  end

  def validate_address_policy_kw(_value), do: {:error, "address_policy keyword list expected"}

  @impl Source
  def resolve(%SourcePath{segments: segments}, opts, runtime_opts) do
    with {:ok, base} <- fetch_base_url(opts),
         :ok <- validate_path(segments, opts) do
      resolve(base_source(base, segments), opts, runtime_opts)
    end
  end

  def resolve(%URL{scheme: scheme} = source, opts, _runtime_opts)
      when scheme in [:http, :https] do
    host = String.downcase(source.host)

    if host in Keyword.fetch!(opts, :allowed_hosts) do
      port = source.port || Map.fetch!(@default_ports, scheme)

      identity = [
        kind: :url,
        adapter: scheme,
        scheme: scheme,
        host: host,
        port: port,
        path: source.path,
        query: source.query
      ]

      stable? = CacheSettings.trusted?(opts)

      cache =
        CacheSettings.fields(opts,
          stable?: stable?,
          seed: redacted_http_identity(identity),
          auto: :enabled
        )

      {:ok,
       struct!(
         Resolved,
         [
           source_kind: :url,
           identity: identity,
           fetch: [
             url: build_url(%{source | host: host, port: port}),
             strip_byte_headers: stable? or cache[:internal_cache] == :enabled
           ]
         ] ++ cache
       )}
    else
      {:error, {:source, :denied_host}}
    end
  end

  defp fetch_base_url(opts) do
    case Keyword.fetch(opts, :base_url) do
      {:ok, base} -> {:ok, base}
      :error -> {:error, {:source, :missing_adapter}}
    end
  end

  # Origins may normalize dot segments, which would escape the base path.
  defp validate_path(segments, opts) do
    cond do
      Enum.any?(segments, &(&1 in ["", ".", ".."])) ->
        {:error, {:source, :denied_path}}

      not path_allowed?(Enum.join(segments, "/"), opts[:path_pattern]) ->
        {:error, {:source, :denied_path}}

      true ->
        :ok
    end
  end

  defp path_allowed?(_path, nil), do: true
  defp path_allowed?(path, pattern), do: Regex.match?(pattern, path)

  defp base_source(base, segments),
    do: %URL{scheme: base.scheme, host: base.host, port: base.port, path: base.path ++ segments}

  @impl Source
  def fetch(%Resolved{fetch: fetch}, opts, runtime_opts) do
    req_options =
      fetch
      |> Keyword.get(:prepared_req_options, Keyword.fetch!(opts, :req_options))
      |> ReqSanitizer.sanitize_req_options(
        @internal_option_keys,
        @host_header_names,
        fetch[:strip_byte_headers]
      )
      |> Keyword.merge(url: fetch[:url], method: :get)

    stream_options =
      Keyword.take(opts, [:receive_timeout, :pool_timeout, :connect_timeout])
      |> Keyword.merge(runtime_opts)
      |> Keyword.put(:validate_target, build_target_guard(opts))
      |> Keyword.put(:max_redirects, Keyword.fetch!(opts, :max_redirects))

    ReqStream.open(req_options, stream_options)
  end

  @doc false
  def prepare_cache(%Resolved{} = source, opts, _runtime) do
    req = Auth.freeze(opts[:req_options], source.fetch[:url])
    {:ok, %{source | fetch: Keyword.put(source.fetch, :prepared_req_options, req)}}
  end

  defp build_target_guard(opts) do
    allowed_hosts = Keyword.fetch!(opts, :allowed_hosts)
    predicate = AddressPolicy.compile(Keyword.fetch!(opts, :address_policy))
    resolver = Keyword.get(opts, :address_resolver, &TargetGuard.default_resolver/1)

    fn url -> TargetGuard.validate(url, allowed_hosts, predicate, resolver) end
  end

  defp redacted_http_identity(identity) do
    case Keyword.fetch!(identity, :query) do
      nil ->
        Keyword.delete(identity, :query)

      query ->
        identity
        |> Keyword.delete(:query)
        |> Keyword.put(:query_sha256, :crypto.hash(:sha256, query) |> Base.encode16(case: :lower))
    end
  end

  defp build_url(%URL{} = source) do
    path =
      Enum.map_join(source.path, "/", fn segment ->
        URI.encode(segment, &URI.char_unreserved?/1)
      end)

    path = "/" <> path
    port = source.port || Map.fetch!(@default_ports, source.scheme)
    authority = authority_host(source.host) <> port_suffix(source.scheme, port)
    query = if is_binary(source.query), do: "?" <> source.query, else: ""

    "#{source.scheme}://#{authority}#{path}#{query}"
  end

  defp authority_host(host) do
    if String.contains?(host, ":") do
      "[#{host}]"
    else
      host
    end
  end

  defp port_suffix(:http, 80), do: ""
  defp port_suffix(:https, 443), do: ""
  defp port_suffix(_scheme, port), do: ":#{port}"
end
