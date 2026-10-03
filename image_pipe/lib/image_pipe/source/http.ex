defmodule ImagePipe.Source.HTTP do
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
                      allowed_hosts: [
                        type: {:list, :string},
                        doc: """
                        Hostnames the adapter may connect to, compared without case. \
                        Redirects can't leave the list. Required unless `:base_url` \
                        is set, which defaults it to the base URL's host. A list given \
                        with `:base_url` must include that host.
                        """
                      ],
                      base_url: [
                        type: :string,
                        doc: """
                        Origin that path sources are served from, such as \
                        `"https://images.example.com/originals"`. Each path segment \
                        is percent-encoded and appended, so `beach.jpg` fetches \
                        `https://images.example.com/originals/beach.jpg`. Must be an \
                        `http` or `https` URL with a host and no query, fragment, or \
                        credentials. Without it, the adapter serves only URL sources.
                        """
                      ],
                      path_pattern: [
                        type: {:struct, Regex},
                        type_doc: "`t:Regex.t/0`",
                        doc: """
                        Regular expression that the whole path, segments joined with \
                        `/`, must match. Other paths are not found, and the origin is \
                        never contacted. Requires `:base_url`.
                        """
                      ],
                      req_options: [
                        type: :keyword_list,
                        default: [],
                        doc: """
                        Options for `Req.request/1`, such as `headers:` or `auth:`. \
                        The adapter drops `:url`, `:base_url`, `:method`, `:body`, \
                        `:params`, `:into`, `:retry`, `:redirect`, and `:max_redirects`, \
                        and a `host` header. \
                        It also drops `range`, `accept`, and `accept-encoding` headers, \
                        except on a source with `internal_cache: :disabled` that isn't \
                        immutable. Requests for one URL must always return the same \
                        bytes, because cached originals and processed images are \
                        reused per URL.
                        """
                      ],
                      receive_timeout: [
                        type: :non_neg_integer,
                        doc: """
                        Milliseconds to wait for the response and between body \
                        chunks. The default value is `5000`.
                        """
                      ],
                      connect_timeout: [
                        type: :non_neg_integer,
                        doc: "Milliseconds to wait for a connection. The default value is `5000`."
                      ],
                      pool_timeout: [
                        type: :non_neg_integer,
                        doc: """
                        Milliseconds to wait for a free connection from the pool. \
                        The default value is `5000`.
                        """
                      ],
                      max_redirects: [
                        type: :non_neg_integer,
                        default: 0,
                        doc: """
                        Redirects to follow. Each target is checked against \
                        `:allowed_hosts` and `:address_policy`. A redirect beyond the \
                        limit fails the request with `502`.
                        """
                      ],
                      address_policy: [
                        type:
                          {:or,
                           [{:fun, 2}, {:custom, __MODULE__, :validate_address_policy_kw, []}]},
                        type_doc: "`t:keyword/0` or `(:inet.ip_address(), atom() -> boolean())`",
                        default: [],
                        doc: """
                        Which non-public addresses the adapter may connect to. See \
                        [Address policy](#module-address-policy).
                        """
                      ],
                      address_resolver: [
                        type: {:fun, 1},
                        type_doc:
                          "`(String.t() -> {:ok, [:inet.ip_address()]} | {:error, term()})`",
                        doc: """
                        Resolves a hostname to the addresses to check and connect to, \
                        such as a caching resolver. Addresses are tried in the order \
                        returned, without duplicates. An error, an empty list, or an \
                        exception denies the fetch. The default resolver returns IPv4 \
                        addresses before IPv6 addresses.
                        """
                      ]
                    ] ++ CacheSettings.schema()
                  )

  @moduledoc """
  Source adapter for images fetched over HTTP and HTTPS.

      web: [
        adapter: ImagePipe.Source.HTTP,
        match: [scheme: ["http", "https"]],
        options: [allowed_hosts: ["assets.example.com"]]
      ]

  It resolves URL sources such as `https://assets.example.com/beach.jpg` and,
  with `:base_url`, path sources. Setting up a mount is covered in
  [Serving images from an HTTP origin](serving-from-http.md).

  Before connecting, and again for each redirect, the adapter checks the
  scheme and host, resolves the host, and denies the fetch unless every
  resolved address is public or allowed by `:address_policy`. It then connects
  to a checked address while keeping the hostname for the `Host` header and
  TLS verification. Why is explained in
  [Source network policy](source-network-policy.md). A denied fetch fails
  with `{:source, :denied_scheme}`, `{:source, :denied_host}`, or
  `{:source, :denied_address}`, which answer `404`. Connecting to a checked
  address applies to Req's default transport. A Req adapter given in
  `:req_options` makes its own connections.

  ## Options

  #{NimbleOptions.docs(@options_schema)}

  ## Address policy

  By default the adapter connects only to public addresses. `:address_policy`
  takes a keyword list that also allows some categories or ranges:

      address_policy: [allow: ["10.0.5.0/24"], allow_loopback: true]

    * `:allow` - a list of CIDR ranges, such as `"10.0.5.0/24"` or
      `"fd00::/8"`.
    * `:allow_loopback` - `127.0.0.0/8` and `::1`.
    * `:allow_unspecified` - `0.0.0.0/8` and `::`.
    * `:allow_link_local` - `169.254.0.0/16` and `fe80::/10`.
    * `:allow_private` - `10.0.0.0/8`, `172.16.0.0/12`, and `192.168.0.0/16`.
    * `:allow_unique_local` - `fc00::/7`.
    * `:allow_multicast` - `224.0.0.0/4` and `ff00::/8`.
    * `:allow_broadcast` - `255.255.255.255`.
    * `:allow_cgnat` - `100.64.0.0/10`.
    * `:allow_reserved` - other non-public ranges: benchmarking and
      documentation ranges, `240.0.0.0/4`, NAT64 `64:ff9b::/96`, and IPv6
      addresses outside `2000::/3`.

  Each category takes `true` or `false`. Categories treat IPv4-mapped and
  6to4 IPv6 addresses as the IPv4 address they contain. An IPv4 range in
  `:allow` also matches an address in IPv4-mapped form, such as
  `::ffff:10.0.5.7`, but not in 6to4 form.

  Or pass a function that receives each resolved address as a tuple and its
  category (`:public`, or one of the categories above without `allow_`) and
  returns `true` to allow it. It replaces the built-in decision, and any
  result other than `true`, or an exception, denies the address:

      address_policy: fn _ip, category -> category in [:public, :private] end
  """

  @doc false
  def options_schema, do: @options_schema.schema

  @impl Source
  def identifiers, do: [SourcePath, URL]

  @impl Source
  def validate_options(opts) do
    with {:ok, validated} <- validate_schema(opts),
         {:ok, validated} <- validate_base_url(validated) do
      validated
      |> Keyword.update!(:allowed_hosts, fn hosts -> Enum.map(hosts, &String.downcase/1) end)
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

      stable? = CacheSettings.immutable?(opts)

      cache =
        CacheSettings.fields(opts,
          stable?: stable?,
          seed: redacted_http_identity(identity),
          copy?: true
        )

      {:ok,
       struct!(
         Resolved,
         [
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
