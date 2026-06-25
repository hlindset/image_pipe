defmodule ImagePipe.Source.S3 do
  @moduledoc false

  @behaviour ImagePipe.Source

  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.S3.Credentials

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
    :auth,
    :aws_sigv4
  ]
  @signed_header_names ["authorization", "host", "x-amz-content-sha256", "x-amz-security-token"]
  @timeout_keys [:receive_timeout, :connect_timeout, :pool_timeout]
  @config_schema NimbleOptions.new!(
                   region: [
                     type: {:custom, __MODULE__, :validate_region_option, []},
                     required: true
                   ],
                   endpoint: [
                     type: {:custom, __MODULE__, :validate_endpoint_option, []},
                     required: true
                   ],
                   credentials: [
                     type: {:custom, __MODULE__, :validate_credentials_option, []}
                   ],
                   req_options: [type: :keyword_list, default: []],
                   stable: [type: {:in, [:auto, :trusted]}, default: :auto],
                   internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
                   http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit],
                   receive_timeout: [type: :non_neg_integer],
                   connect_timeout: [type: :non_neg_integer],
                   pool_timeout: [type: :non_neg_integer]
                 )
  @options_schema NimbleOptions.new!(
                    default: [type: :keyword_list, default: []],
                    buckets: [
                      type: {:or, [nil, {:map, :string, :keyword_list}]},
                      default: nil
                    ]
                  )

  @impl Source
  def validate_options(opts) when is_list(opts) do
    with {:ok, validated} <- validate_options_schema(opts),
         {:ok, default} <- validate_config(Keyword.fetch!(validated, :default)),
         {:ok, buckets} <- validate_buckets(Keyword.fetch!(validated, :buckets), default) do
      {:ok, [default: default, buckets: buckets, telemetry_kind: :s3]}
    end
  end

  def validate_options(_opts), do: {:error, {:invalid_source_config, :invalid_options}}

  @impl Source
  def resolve(
        %Object{adapter: :s3, scope: bucket, key: key, revision: revision},
        opts,
        _runtime_opts
      )
      when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" and
             (is_binary(revision) or is_nil(revision)) do
    with {:ok, config} <- bucket_config(bucket, opts) do
      endpoint = Keyword.fetch!(config, :endpoint)

      identity = [
        kind: :object,
        adapter: :s3,
        endpoint: endpoint,
        bucket: bucket,
        key: key,
        revision: revision
      ]

      stable? = s3_stable?(config, revision)
      internal_cache = internal_cache_mode(config, stable?)

      {:ok,
       %Resolved{
         adapter: :s3,
         source_kind: :object,
         identity: identity,
         internal_cache: internal_cache,
         http_cache: Keyword.fetch!(config, :http_cache),
         cache_semantics: cache_semantics(stable?, identity),
         fetch:
           [
             endpoint: endpoint,
             bucket: bucket,
             key: key,
             revision: revision,
             region: Keyword.fetch!(config, :region),
             credentials: Keyword.get(config, :credentials),
             req_options: Keyword.fetch!(config, :req_options),
             strip_byte_headers: stable? or internal_cache == :enabled
           ]
           |> Keyword.merge(Keyword.take(config, @timeout_keys))
       }}
    end
  end

  def resolve(%Object{adapter: :s3}, _opts, _runtime_opts),
    do: {:error, {:source, :invalid_object}}

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, runtime_opts) do
    with {:ok, credentials} <-
           Credentials.fetch(fetch[:bucket], fetch[:credentials], runtime_opts) do
      req_options =
        fetch
        |> Keyword.fetch!(:req_options)
        |> ReqSanitizer.sanitize_req_options(
          @internal_option_keys,
          @signed_header_names,
          fetch[:strip_byte_headers]
        )
        |> Keyword.merge(
          url: build_url(fetch),
          method: :get,
          max_redirects: 0,
          aws_sigv4: aws_sigv4_options(fetch[:region], credentials)
        )

      stream_options =
        fetch
        |> Keyword.take(@timeout_keys)
        |> Keyword.merge(runtime_opts)

      {:ok, %Response{stream: ReqStream.stream(req_options, stream_options)}}
    end
  end

  defp validate_options_schema(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  defp validate_buckets(nil, default) do
    with :ok <- require_credentials(default) do
      {:ok, nil}
    end
  end

  defp validate_buckets(buckets, default) when is_map(buckets) do
    Enum.reduce_while(buckets, {:ok, %{}}, fn
      {bucket, opts}, {:ok, acc} when is_binary(bucket) and bucket != "" and is_list(opts) ->
        case validate_bucket(default, opts) do
          {:ok, config} -> {:cont, {:ok, Map.put(acc, bucket, config)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, {:invalid_source_config, :invalid_bucket_config}}}
    end)
  end

  defp validate_buckets(_buckets, _default),
    do: {:error, {:invalid_source_config, :invalid_bucket_config}}

  defp validate_bucket(default, opts) do
    merged = Keyword.merge(default, opts)

    with {:ok, config} <- validate_config(merged),
         :ok <- require_credentials(config) do
      {:ok, config}
    end
  end

  defp validate_config(opts) do
    case NimbleOptions.validate(opts, @config_schema) do
      {:ok, validated} -> {:ok, remove_nil_credentials(validated)}
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @doc false
  def validate_endpoint_option(endpoint) do
    case validate_endpoint(endpoint) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, _reason} -> {:error, "expected HTTP(S) endpoint without path, query, or fragment"}
    end
  end

  defp validate_endpoint(endpoint) when is_binary(endpoint) do
    uri = URI.parse(endpoint)

    case uri do
      %URI{
        scheme: scheme,
        host: host,
        userinfo: nil,
        path: path,
        query: nil,
        fragment: nil
      }
      when scheme in ["http", "https"] and is_binary(host) and host != "" and
             path in [nil, "", "/"] ->
        with :ok <- validate_endpoint_port(endpoint, scheme) do
          {:ok, String.trim_trailing(endpoint, "/")}
        end

      _uri ->
        {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  defp validate_endpoint(_endpoint), do: {:error, {:invalid_source_config, :invalid_endpoint}}

  defp validate_endpoint_port(endpoint, scheme) do
    endpoint
    |> String.replace_prefix(scheme <> "://", "")
    |> endpoint_authority()
    |> validate_authority_port()
  end

  defp endpoint_authority(rest) do
    rest
    |> String.split(["/", "?", "#"], parts: 2)
    |> hd()
  end

  defp validate_authority_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [_host, ""] -> :ok
      [_host, ":" <> port] -> validate_port(port)
      _other -> {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  defp validate_authority_port(authority) do
    case String.split(authority, ":", parts: 2) do
      [_host] -> :ok
      [_host, port] -> validate_port(port)
    end
  end

  defp validate_port(port) do
    if String.match?(port, ~r/^[0-9]+$/) do
      case Integer.parse(port) do
        {port, ""} when port in 1..65_535 -> :ok
        _invalid -> {:error, {:invalid_source_config, :invalid_endpoint}}
      end
    else
      {:error, {:invalid_source_config, :invalid_endpoint}}
    end
  end

  @doc false
  def validate_region_option(region) when is_binary(region) and region != "", do: {:ok, region}
  def validate_region_option(_region), do: {:error, "expected non-empty string"}

  @doc false
  def validate_credentials_option(nil), do: {:ok, nil}

  def validate_credentials_option(credentials) do
    case Credentials.validate(credentials) do
      {:ok, credentials} -> {:ok, credentials}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp require_credentials(config) do
    if Keyword.has_key?(config, :credentials) do
      :ok
    else
      {:error, {:invalid_source_config, :missing_credentials}}
    end
  end

  defp remove_nil_credentials(config), do: Keyword.reject(config, &(&1 == {:credentials, nil}))

  defp bucket_config(bucket, opts) do
    case Keyword.fetch!(opts, :buckets) do
      nil ->
        {:ok, Keyword.fetch!(opts, :default)}

      buckets ->
        case Map.fetch(buckets, bucket) do
          {:ok, config} -> {:ok, config}
          :error -> {:error, {:source, :denied_bucket}}
        end
    end
  end

  defp s3_stable?(config, revision) do
    Keyword.fetch!(config, :stable) == :trusted or
      (is_binary(revision) and revision != "")
  end

  defp internal_cache_mode(config, stable?) do
    case Keyword.fetch!(config, :internal_cache) do
      :enabled -> :enabled
      :disabled -> :disabled
      :auto -> if stable?, do: :enabled, else: :disabled
    end
  end

  defp cache_semantics(true, identity),
    do: %CacheSemantics{byte_identity: {:strong, identity}, stable?: true}

  defp cache_semantics(false, _identity),
    do: %CacheSemantics{byte_identity: :none, stable?: false}

  defp aws_sigv4_options(region, credentials) do
    credentials
    |> Keyword.put(:service, :s3)
    |> Keyword.put(:region, region)
  end

  defp build_url(fetch) do
    endpoint = Keyword.fetch!(fetch, :endpoint)
    bucket = Keyword.fetch!(fetch, :bucket)
    key = Keyword.fetch!(fetch, :key)
    revision = Keyword.get(fetch, :revision)

    IO.iodata_to_binary([
      endpoint,
      "/",
      encode_path_segment(bucket),
      "/",
      encode_key(key),
      revision_query(revision)
    ])
  end

  defp encode_key(key) do
    key
    |> String.split("/", trim: false)
    |> Enum.map_join("/", &encode_path_segment/1)
  end

  defp encode_path_segment(segment), do: URI.encode(segment, &URI.char_unreserved?/1)

  defp revision_query(nil), do: ""

  defp revision_query(revision),
    do: ["?versionId=", URI.encode(revision, &URI.char_unreserved?/1)]
end
