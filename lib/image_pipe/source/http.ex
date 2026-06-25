defmodule ImagePipe.Source.HTTP do
  @moduledoc false

  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.HTTP.AddressPolicy
  alias ImagePipe.Source.HTTP.TargetGuard
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

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

  @options_schema NimbleOptions.new!(
                    allowed_hosts: [type: {:list, :string}, required: true],
                    req_options: [type: :keyword_list, default: []],
                    receive_timeout: [type: :non_neg_integer],
                    connect_timeout: [type: :non_neg_integer],
                    pool_timeout: [type: :non_neg_integer],
                    max_redirects: [type: :non_neg_integer, default: 0],
                    stable: [type: {:in, [:auto, :trusted]}, default: :auto],
                    internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
                    http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit],
                    address_policy: [
                      type:
                        {:or, [{:fun, 2}, {:custom, __MODULE__, :validate_address_policy_kw, []}]},
                      default: []
                    ],
                    address_resolver: [type: {:fun, 1}]
                  )

  @impl Source
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} ->
        normalized =
          validated
          |> Keyword.update!(:allowed_hosts, fn hosts -> Enum.map(hosts, &String.downcase/1) end)
          |> Keyword.put(:telemetry_kind, :http)

        {:ok, normalized}

      {:error, error} ->
        {:error, {:invalid_source_config, Exception.message(error)}}
    end
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

      stable? = Keyword.fetch!(opts, :stable) == :trusted
      internal_cache = internal_cache_mode(opts, stable?)

      {:ok,
       %Resolved{
         adapter: scheme,
         source_kind: :url,
         identity: identity,
         internal_cache: internal_cache,
         http_cache: Keyword.fetch!(opts, :http_cache),
         cache_semantics: cache_semantics(opts, stable?, identity),
         fetch: [
           url: build_url(%{source | host: host, port: port}),
           strip_byte_headers: stable? or internal_cache == :enabled
         ]
       }}
    else
      {:error, {:source, :denied_host}}
    end
  end

  @impl Source
  def fetch(%Resolved{fetch: fetch}, opts, runtime_opts) do
    req_options =
      opts
      |> Keyword.fetch!(:req_options)
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

    {:ok, %Response{stream: ReqStream.stream(req_options, stream_options)}}
  end

  defp build_target_guard(opts) do
    allowed_hosts = Keyword.fetch!(opts, :allowed_hosts)
    predicate = AddressPolicy.compile(Keyword.fetch!(opts, :address_policy))
    resolver = Keyword.get(opts, :address_resolver, &TargetGuard.default_resolver/1)

    fn url -> TargetGuard.validate(url, allowed_hosts, predicate, resolver) end
  end

  defp internal_cache_mode(opts, stable?) do
    case Keyword.fetch!(opts, :internal_cache) do
      :enabled -> :enabled
      :disabled -> :disabled
      :auto -> if stable?, do: :enabled, else: :disabled
    end
  end

  defp cache_semantics(_opts, stable?, identity) do
    byte_identity =
      if stable? do
        {:strong, redacted_http_identity(identity)}
      else
        :none
      end

    %CacheSemantics{byte_identity: byte_identity, stable?: stable?}
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
