defmodule ImagePipeServer.Config.Sources do
  @moduledoc """
  Converts `[sources.<name>]` tables to named source mounts.

  Each table names a built-in `adapter` (`"file"`, `"http"`, or `"s3"`) and a
  `match` (`"path"`, or a table of `prefix` and `scheme` rules). Its other
  keys are the adapter's options, converted with the adapter's schema. The
  table name becomes the mount name.

  Explicit conversions:

    * HTTP `path_pattern` compiles to a `Regex`.
    * HTTP `request_headers` and `bearer_token` become `req_options` headers
      and bearer auth; `req_options` itself stays Elixir-only.
    * HTTP `address_policy` takes its keyword form as a table.
    * `cache_policy` converts with `ImagePipe.Source.CachePolicy`'s schema.
    * S3 settings outside `buckets` form the `:default` configuration, and
      each `buckets` table overrides it for one bucket.
    * S3 `credentials` is `{ static = { access_key_id, secret_access_key,
      token } }` or `{ provider = "<name>", ...options }`, where the provider
      is `instance_role`, `container_credentials`, `web_identity`, or
      `assume_role`. `assume_role` takes its `base` credentials the same way.
  """

  alias ImagePipe.Source.CachePolicy
  alias ImagePipe.Source.File, as: FileSource
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.S3
  alias ImagePipe.Source.S3.AssumeRole
  alias ImagePipe.Source.S3.ContainerCredentials
  alias ImagePipe.Source.S3.InstanceRole
  alias ImagePipe.Source.S3.WebIdentity
  alias ImagePipeServer.Config.Convert

  @adapters %{"file" => FileSource, "http" => HTTP, "s3" => S3}
  @providers %{
    "instance_role" => InstanceRole,
    "container_credentials" => ContainerCredentials,
    "web_identity" => WebIdentity,
    "assume_role" => AssumeRole
  }
  @rules {:or, [{:list, :string}, :string]}
  @address_categories [
    :allow_loopback,
    :allow_unspecified,
    :allow_link_local,
    :allow_private,
    :allow_unique_local,
    :allow_multicast,
    :allow_broadcast,
    :allow_cgnat,
    :allow_reserved
  ]

  @doc "Converts the `[sources]` table, raising `ImagePipeServer.ConfigError`."
  @spec options!(term()) :: keyword()
  def options!(table) do
    case convert(table, ["sources"]) do
      {:ok, sources} ->
        sources

      {:error, path, message} ->
        raise ImagePipeServer.ConfigError, Convert.error_message(path, message)
    end
  end

  @doc "Converts the `[sources]` table."
  @spec convert(term(), Convert.path()) :: Convert.result()
  def convert(%{} = table, path) do
    with {:ok, mounts} <- Convert.value({:map, :string, {:convert, &mount/2}}, table, path) do
      # Mount names are the operator's own identifiers, fixed at boot.
      {:ok,
       mounts |> Enum.sort() |> Enum.map(fn {name, mount} -> {String.to_atom(name), mount} end)}
    end
  end

  def convert(_value, path), do: {:error, path, "expected a table"}

  defp mount(%{} = table, path) do
    with {:ok, name} <- required(table, "adapter", path),
         {:ok, module} <- adapter(name, path ++ ["adapter"]),
         {:ok, match} <- required(table, "match", path),
         {:ok, match} <- match(match, path ++ ["match"]),
         {:ok, options} <- adapter_options(module, Map.drop(table, ["adapter", "match"]), path) do
      {:ok, [adapter: module, match: match, options: options]}
    end
  end

  defp mount(_value, path), do: {:error, path, "expected a table"}

  defp required(table, key, path) do
    case Map.fetch(table, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, path ++ [key], "required"}
    end
  end

  defp adapter(value, path) do
    with {:ok, name} <- Convert.string(value, path) do
      case Map.fetch(@adapters, name) do
        {:ok, module} -> {:ok, module}
        :error -> {:error, path, "expected one of file, http, s3"}
      end
    end
  end

  defp match(value, path) do
    case Convert.string(value, path) do
      {:ok, "path"} ->
        {:ok, :path}

      {:ok, _other} ->
        {:error, path, ~s(expected "path" or a table of prefix and scheme rules)}

      {:error, _path, _message} ->
        Convert.options(value, [prefix: [type: @rules], scheme: [type: @rules]], path)
    end
  end

  defp adapter_options(FileSource, table, path),
    do: Convert.options(table, with_cache_policy(FileSource.options_schema()), path)

  defp adapter_options(HTTP, table, path) do
    with {:ok, options} <- Convert.options(table, http_schema(), path) do
      {headers, options} = Keyword.pop(options, :request_headers)
      {token, options} = Keyword.pop(options, :bearer_token)

      req_options =
        Enum.reject(
          [headers: headers && Enum.to_list(headers), auth: token && {:bearer, token}],
          fn {_key, value} -> is_nil(value) end
        )

      {:ok, if(req_options == [], do: options, else: options ++ [req_options: req_options])}
    end
  end

  defp adapter_options(S3, table, path) do
    {buckets, table} = Map.pop(table, "buckets")
    bucket = {:convert, &Convert.options(&1, s3_schema(), &2)}

    with {:ok, default} <- Convert.options(table, s3_schema(), path),
         {:ok, buckets} <- s3_buckets(buckets, bucket, path ++ ["buckets"]) do
      {:ok, [default: default] ++ buckets}
    end
  end

  defp s3_buckets(nil, _bucket, _path), do: {:ok, []}

  defp s3_buckets(buckets, bucket, path) do
    with {:ok, buckets} <- Convert.value({:map, :string, bucket}, buckets, path),
         do: {:ok, [buckets: buckets]}
  end

  defp http_schema do
    HTTP.options_schema()
    |> with_cache_policy()
    |> Keyword.merge(
      path_pattern: [type: {:convert, &regex/2}],
      address_policy: [type: {:convert, &address_policy/2}],
      request_headers: [type: {:map, :string, :string}],
      bearer_token: [type: :string]
    )
  end

  defp s3_schema do
    S3.config_schema()
    |> with_cache_policy()
    |> Keyword.merge(credentials: [type: {:convert, &credentials/2}])
  end

  defp with_cache_policy(schema) do
    Keyword.merge(schema, cache_policy: [type: {:convert, &cache_policy/2}])
  end

  @doc false
  @spec cache_policy(term(), Convert.path()) :: Convert.result()
  def cache_policy(value, path), do: Convert.options(value, CachePolicy.options_schema(), path)

  defp regex(value, path) do
    with {:ok, source} <- Convert.string(value, path) do
      case Regex.compile(source) do
        {:ok, regex} -> {:ok, regex}
        {:error, _reason} -> {:error, path, "invalid regular expression"}
      end
    end
  end

  defp address_policy(value, path) do
    schema =
      [allow: [type: {:list, :string}]] ++
        Enum.map(@address_categories, &{&1, [type: :boolean]})

    Convert.options(value, schema, path)
  end

  defp credentials(%{"static" => static} = table, path) when map_size(table) == 1 do
    schema = [
      access_key_id: [type: :string],
      secret_access_key: [type: :string],
      token: [type: :string]
    ]

    with {:ok, static} <- Convert.options(static, schema, path ++ ["static"]),
         do: {:ok, {:static, static}}
  end

  defp credentials(%{"provider" => provider} = table, path) do
    with {:ok, name} <- Convert.string(provider, path ++ ["provider"]),
         {:ok, module} <- provider(name, path ++ ["provider"]),
         {:ok, options} <-
           Convert.options(Map.delete(table, "provider"), provider_schema(module), path),
         do: {:ok, {:provider, module, options}}
  end

  defp credentials(_value, path),
    do: {:error, path, "expected { static = {...} } or { provider = \"...\" }"}

  defp provider(name, path) do
    case Map.fetch(@providers, name) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        {:error, path, "expected one of #{@providers |> Map.keys() |> Enum.join(", ")}"}
    end
  end

  # `plug` is a test hook for the metadata request.
  defp provider_schema(module) do
    schema = Keyword.delete(module.options_schema(), :plug)

    if Keyword.has_key?(schema, :base),
      do: Keyword.put(schema, :base, type: {:convert, &credentials/2}),
      else: schema
  end
end
