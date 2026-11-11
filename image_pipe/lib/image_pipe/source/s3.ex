defmodule ImagePipe.Source.S3 do
  @behaviour ImagePipe.Source

  alias ImagePipe.Source
  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.CacheSettings
  alias ImagePipe.Source.Object
  alias ImagePipe.Source.ReqSanitizer
  alias ImagePipe.Source.ReqStream
  alias ImagePipe.Source.Resolved
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
  @dns_name ~r/\A[a-z0-9]+(?:-+[a-z0-9]+)*(?:\.[a-z0-9]+(?:-+[a-z0-9]+)*)*\z/
  @connection_keys [
    :receive_timeout,
    :fetch_timeout,
    :connect_timeout,
    :pool_timeout,
    :pool_size
  ]
  @config_schema NimbleOptions.new!(
                   [
                     region: [
                       type: {:custom, __MODULE__, :validate_region_option, []},
                       type_doc: "`t:String.t/0`",
                       required: true,
                       doc: "Region used to sign requests, such as `\"us-east-1\"`."
                     ],
                     endpoint: [
                       type: {:custom, __MODULE__, :validate_endpoint_option, []},
                       type_doc: "`t:String.t/0`",
                       required: true,
                       doc: """
                       Base URL of the S3 API, such as \
                       `"https://s3.us-east-1.amazonaws.com"`, with no path, query, or \
                       fragment.
                       """
                     ],
                     addressing: [
                       type: {:in, [:path, :virtual_host]},
                       default: :path,
                       doc: """
                       Where the bucket name goes in an object's URL. `:path` requests \
                       `<endpoint>/<bucket>/<key>`. `:virtual_host` puts the bucket in \
                       front of the endpoint's host, as \
                       `https://<bucket>.<endpoint host>/<key>`, which \
                       [S3 Transfer Acceleration](serving-from-s3.md#use-s3-transfer-acceleration) \
                       and some S3-compatible stores require. `:virtual_host` needs an \
                       endpoint with a host name, not an IP address, and bucket names \
                       that are DNS names of up to 63 lowercase letters, digits, \
                       hyphens, and dots. A request for any other bucket answers `404`, \
                       and listing one under `:buckets` is a configuration error. A \
                       wildcard TLS certificate, such as Amazon S3's, doesn't cover a \
                       bucket name with a dot.
                       """
                     ],
                     credentials: [
                       type: {:custom, __MODULE__, :validate_credentials_option, []},
                       type_doc: "`{:static, keyword()}` or `{:provider, module(), keyword()}`",
                       doc: """
                       Credentials that sign requests. Every bucket needs them, \
                       from `:default` or its own settings. See \
                       [Credentials](#module-credentials).
                       """
                     ],
                     req_options: [
                       type: :keyword_list,
                       default: [],
                       doc: """
                       Options for `Req.request/1`, such as `headers:`. The adapter \
                       drops the `:url`, `:base_url`, `:method`, `:body`, `:params`, \
                       `:into`, `:retry`, `:redirect`, `:max_redirects`, `:auth`, and \
                       `:aws_sigv4` options, the `authorization`, `host`, \
                       `x-amz-content-sha256`, and `x-amz-security-token` headers, and \
                       the conditional headers `if-none-match`, `if-modified-since`, \
                       `if-match`, `if-unmodified-since`, and `if-range`. It also drops \
                       `range`, `accept`, and `accept-encoding` headers, and the \
                       `:range` option, except on a source with `internal_cache: :disabled` that isn't \
                       immutable. Requests for one object must always return the \
                       same bytes.
                       """
                     ],
                     receive_timeout: [
                       type: :non_neg_integer,
                       doc: """
                       Milliseconds to wait for the response and between body \
                       chunks. The default value is `5000`.
                       """
                     ],
                     fetch_timeout: [
                       type: :pos_integer,
                       doc: """
                       Milliseconds for the whole download, from the request to the \
                       last body byte. A connection attempt can run past it by up \
                       to `connect_timeout`. Requests waiting for another request's \
                       download or check of the same object stop waiting after this \
                       long plus one second. The default value is `30000`.
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
                       A request that waits longer fails with `504`. The default \
                       value is `5000`.
                       """
                     ],
                     pool_size: [
                       type: :pos_integer,
                       doc: """
                       Maximum number of open HTTP/1.1 connections to the endpoint, or \
                       to each bucket's host with `addressing: :virtual_host`. Each \
                       connection carries one download at a time, so further downloads from \
                       the same endpoint wait for a free connection, up to `pool_timeout`. A bucket with a different `pool_size` \
                       or `connect_timeout` connects through a pool of its own. The default \
                       value is `50`.
                       """
                     ]
                   ] ++ CacheSettings.schema()
                 )

  @doc false
  def config_schema, do: @config_schema.schema

  @options_schema NimbleOptions.new!(
                    default: [
                      type: :keyword_list,
                      default: [],
                      doc: """
                      Bucket settings for every bucket. Must include `:region` and \
                      `:endpoint`.
                      """
                    ],
                    buckets: [
                      type: {:or, [nil, {:map, :string, :keyword_list}]},
                      type_doc: "`%{String.t() => keyword()}`",
                      default: nil,
                      doc: """
                      Bucket settings per bucket name, each merged over `:default`. \
                      When given, only the listed buckets are served, and other \
                      buckets are not found. Omitted, every bucket is served.
                      """
                    ]
                  )

  @moduledoc """
  Source adapter for objects in S3 and S3-compatible storage.

      media: [
        adapter: ImagePipe.Source.S3,
        match: [scheme: "s3"],
        options: [
          default: [
            region: "us-east-1",
            endpoint: "https://s3.us-east-1.amazonaws.com",
            credentials: {:provider, ImagePipe.Source.S3.InstanceRole, []}
          ]
        ]
      ]

  It resolves object sources written `s3://bucket/key` or
  `s3://bucket/key?revision`. Setting up a mount is covered in
  [Serving images from S3](serving-from-s3.md).

  A revision is an S3 version ID, written as the whole query
  (`?3HL4kqtJlcpX`, not `?versionId=3HL4kqtJlcpX`). The adapter requests that
  version, and the object is treated as immutable. The response must carry a
  matching `x-amz-version-id` header, or the fetch fails with `502`. Without a
  revision, the object's `Cache-Control`, `ETag`, and `Last-Modified` headers
  set its cache lifetime, as for an HTTP source.

  ## Options

  #{@options_schema.schema |> Keyword.update!(:buckets, &Keyword.delete(&1, :default)) |> NimbleOptions.docs()}

  ## Bucket settings

  `:default` and each entry of `:buckets` take these settings:

  #{NimbleOptions.docs(@config_schema)}

  ## Credentials

    * `{:static, access_key_id: id, secret_access_key: secret}` - fixed keys.
      Add `token:` for temporary credentials with a session token. A `nil`
      token is the same as leaving `token:` out, and an empty string is
      rejected.
    * `{:provider, module, options}` - a module implementing
      `ImagePipe.Source.S3.CredentialProvider`, which fetches credentials
      and refreshes them before they expire. ImagePipe includes
      `ImagePipe.Source.S3.InstanceRole`,
      `ImagePipe.Source.S3.ContainerCredentials`,
      `ImagePipe.Source.S3.WebIdentity`, and
      `ImagePipe.Source.S3.AssumeRole`.

  Credentials from a provider are cached per provider and options, and
  shared by every bucket that uses them.
  Expired credentials are never sent. When they can't be refreshed, requests
  fail with `{:source, :credentials_unavailable}`, which answers `500`.

  A failed fetch logs a warning, with the failure reason when it's an atom.
  Further failures in a row log nothing more, and the fetch that succeeds
  after them logs at info level.
  """

  @impl Source
  def identifiers(_options), do: [Object]

  @impl Source
  def validate_options(opts) when is_list(opts) do
    with {:ok, validated} <- validate_options_schema(opts),
         {:ok, default} <- validate_config(Keyword.fetch!(validated, :default)),
         {:ok, default} <- CacheSettings.validate(default),
         {:ok, buckets} <- validate_buckets(Keyword.fetch!(validated, :buckets), default) do
      {:ok, [default: default, buckets: buckets]}
    end
  end

  def validate_options(_opts), do: {:error, {:invalid_source_config, :invalid_options}}

  @impl Source
  def resolve(
        %Object{scheme: "s3", scope: bucket, key: key, revision: revision},
        opts,
        _runtime_opts
      )
      when is_binary(bucket) and bucket != "" and is_binary(key) and key != "" and
             (is_binary(revision) or is_nil(revision)) do
    with {:ok, config} <- bucket_config(bucket, opts),
         :ok <- addressable_bucket(bucket, config) do
      endpoint = Keyword.fetch!(config, :endpoint)

      identity = [
        kind: :object,
        adapter: :s3,
        endpoint: endpoint,
        bucket: bucket,
        key: key,
        revision: revision
      ]

      # A version ID pins the object's bytes, so a revision makes it stable.
      stable? = CacheSettings.immutable?(config) or revision != nil
      cache = CacheSettings.fields(config, stable?: stable?, seed: identity, copy?: true)

      fetch =
        [
          endpoint: endpoint,
          addressing: Keyword.fetch!(config, :addressing),
          bucket: bucket,
          key: key,
          revision: revision,
          region: Keyword.fetch!(config, :region),
          credentials: Keyword.get(config, :credentials),
          req_options: Keyword.fetch!(config, :req_options),
          strip_byte_headers: stable? or cache[:internal_cache] == :enabled
        ]
        |> Keyword.merge(Keyword.take(config, @connection_keys))
        |> Keyword.put_new(:fetch_timeout, 30_000)

      {:ok, struct!(Resolved, [identity: identity, fetch: fetch] ++ cache)}
    end
  end

  def resolve(%Object{scheme: "s3"}, _opts, _runtime_opts),
    do: {:error, {:source, :invalid_object}}

  @impl Source
  def fetch(%Resolved{fetch: fetch}, _opts, runtime_opts) do
    with {:ok, credentials} <-
           Credentials.fetch(fetch[:credentials]) do
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
        |> Keyword.take(@connection_keys)
        |> Keyword.merge(runtime_opts)
        |> put_version_check(fetch[:revision])

      ReqStream.open(req_options, stream_options)
    end
  end

  # A pinned revision is treated as immutable, so a store that ignores
  # versionId and returns the current object must not be cached as that version.
  defp put_version_check(stream_options, nil),
    do: stream_options

  defp put_version_check(stream_options, revision) do
    Keyword.put(stream_options, :validate_response, fn response ->
      case Req.Response.get_header(response, "x-amz-version-id") do
        [^revision] -> :ok
        _other -> {:error, :version_mismatch}
      end
    end)
  end

  defp validate_options_schema(opts) do
    case NimbleOptions.validate(opts, @options_schema) do
      {:ok, validated} -> {:ok, validated}
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  @doc false
  def prepare_cache(%Resolved{} = source, _opts, _runtime) do
    with {:ok, credentials} <-
           Credentials.fetch(source.fetch[:credentials]) do
      {:ok, %{source | fetch: Keyword.put(source.fetch, :credentials, {:static, credentials})}}
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
        case validate_bucket(bucket, default, opts) do
          {:ok, config} -> {:cont, {:ok, Map.put(acc, bucket, config)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end

      _entry, _acc ->
        {:halt, {:error, {:invalid_source_config, :invalid_bucket_config}}}
    end)
  end

  defp validate_buckets(_buckets, _default),
    do: {:error, {:invalid_source_config, :invalid_bucket_config}}

  defp validate_bucket(bucket, default, opts) do
    merged = Keyword.merge(default, opts)

    with {:ok, config} <- validate_config(merged),
         :ok <- validate_bucket_name(bucket, config),
         {:ok, _explicit_policy} <-
           CacheSettings.validate(
             Keyword.put(config, :cache_policy, Keyword.get(opts, :cache_policy, []))
           ),
         :ok <- require_credentials(config) do
      policy = CachePolicy.merge(default[:cache_policy], config[:cache_policy])
      {:ok, Keyword.put(config, :cache_policy, policy)}
    end
  end

  defp validate_config(opts) do
    case NimbleOptions.validate(opts, @config_schema) do
      {:ok, validated} -> validated |> remove_nil_credentials() |> validate_addressing()
      {:error, error} -> {:error, {:invalid_source_config, Exception.message(error)}}
    end
  end

  # A bucket name can't go in front of an IP address.
  defp validate_addressing(config) do
    host = URI.parse(Keyword.fetch!(config, :endpoint)).host

    with :virtual_host <- Keyword.fetch!(config, :addressing),
         {:ok, _address} <- :inet.parse_address(String.to_charlist(host)) do
      {:error,
       {:invalid_source_config,
        "addressing: :virtual_host needs an endpoint with a host name, got: #{inspect(host)}"}}
    else
      _named_host_or_path -> {:ok, config}
    end
  end

  defp validate_bucket_name(bucket, config) do
    case addressable_bucket(bucket, config) do
      :ok ->
        :ok

      {:error, _reason} ->
        {:error,
         {:invalid_source_config,
          "addressing: :virtual_host needs a bucket name that is a DNS name, got: #{inspect(bucket)}"}}
    end
  end

  # With virtual-host addressing the bucket name becomes part of the request's
  # host, and bucket names come from request URLs.
  defp addressable_bucket(bucket, config) do
    if Keyword.fetch!(config, :addressing) == :path or
         (byte_size(bucket) <= 63 and String.match?(bucket, @dns_name)) do
      :ok
    else
      {:error, {:source, :invalid_object}}
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
      bucket_url(Keyword.fetch!(fetch, :addressing), endpoint, bucket),
      "/",
      encode_key(key),
      revision_query(revision)
    ])
  end

  defp bucket_url(:path, endpoint, bucket), do: [endpoint, "/", encode_path_segment(bucket)]

  defp bucket_url(:virtual_host, endpoint, bucket) do
    [scheme, authority] = String.split(endpoint, "://", parts: 2)
    [scheme, "://", bucket, ".", authority]
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
