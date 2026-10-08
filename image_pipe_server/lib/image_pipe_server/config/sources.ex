defmodule ImagePipeServer.Config.Sources do
  @moduledoc """
  Converts `[sources.<name>]` tables to the named sources of `ImagePipe.config/1`.

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
    * `container_credentials` and `web_identity` options can come from the
      standard AWS variables (see `with_aws_environment/2`).
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
  @container_variables [
    relative_uri: "AWS_CONTAINER_CREDENTIALS_RELATIVE_URI",
    full_uri: "AWS_CONTAINER_CREDENTIALS_FULL_URI",
    auth_token: "AWS_CONTAINER_AUTHORIZATION_TOKEN",
    auth_token_file: "AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE"
  ]
  @web_identity_variables [
    token_file: "AWS_WEB_IDENTITY_TOKEN_FILE",
    role_arn: "AWS_ROLE_ARN",
    region: "AWS_REGION",
    role_session_name: "AWS_ROLE_SESSION_NAME"
  ]
  @rules {:or, [{:list, :string}, :string]}
  @static_credentials_schema [
    access_key_id: [type: :string],
    secret_access_key: [type: :string],
    token: [type: :string]
  ]
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
  def convert(%{} = table, path) when not is_struct(table) do
    with {:ok, mounts} <-
           Convert.value({:map, :string, {:convert, &mount/2, "table"}}, table, path) do
      # Mount names are the operator's own identifiers, fixed at boot.
      {:ok,
       mounts |> Enum.sort() |> Enum.map(fn {name, mount} -> {String.to_atom(name), mount} end)}
    end
  end

  def convert(_value, path), do: {:error, path, "expected a table"}

  @doc """
  Fills credential provider options from the standard AWS variables in `env`,
  as ECS and EKS set them.

    * `container_credentials` without `relative_uri`, `full_uri`,
      `auth_token`, or `auth_token_file` takes each one whose variable is
      set from `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`,
      `AWS_CONTAINER_CREDENTIALS_FULL_URI`,
      `AWS_CONTAINER_AUTHORIZATION_TOKEN`, and
      `AWS_CONTAINER_AUTHORIZATION_TOKEN_FILE`.
    * `web_identity` takes each option it leaves out from its variable:
      `token_file` from `AWS_WEB_IDENTITY_TOKEN_FILE`, `role_arn` from
      `AWS_ROLE_ARN`, `region` from `AWS_REGION`, and `role_session_name`
      from `AWS_ROLE_SESSION_NAME`.
  """
  @spec with_aws_environment(keyword(), %{String.t() => String.t()}) :: keyword()
  def with_aws_environment(sources, env) do
    Enum.map(sources, fn {name, mount} ->
      if Keyword.fetch!(mount, :adapter) == S3,
        do: {name, Keyword.update!(mount, :options, &s3_aws_environment(&1, env))},
        else: {name, mount}
    end)
  end

  defp s3_aws_environment(options, env) do
    options
    |> Keyword.update!(:default, &settings_aws_environment(&1, env))
    |> Keyword.replace_lazy(:buckets, fn buckets ->
      Map.new(buckets, fn {bucket, settings} ->
        {bucket, settings_aws_environment(settings, env)}
      end)
    end)
  end

  defp settings_aws_environment(settings, env),
    do: Keyword.replace_lazy(settings, :credentials, &credentials_aws_environment(&1, env))

  defp credentials_aws_environment({:provider, AssumeRole, options}, env),
    do:
      {:provider, AssumeRole,
       Keyword.replace_lazy(options, :base, &credentials_aws_environment(&1, env))}

  # The URIs and the token belong together, so a configured one keeps the
  # environment's out.
  defp credentials_aws_environment({:provider, ContainerCredentials, options}, env) do
    if Enum.any?(Keyword.keys(@container_variables), &Keyword.has_key?(options, &1)),
      do: {:provider, ContainerCredentials, options},
      else: {:provider, ContainerCredentials, options ++ env_options(env, @container_variables)}
  end

  defp credentials_aws_environment({:provider, WebIdentity, options}, env),
    do:
      {:provider, WebIdentity, Keyword.merge(env_options(env, @web_identity_variables), options)}

  defp credentials_aws_environment(credentials, _env), do: credentials

  defp env_options(env, variables) do
    for {key, variable} <- variables,
        value = Map.get(env, variable),
        value not in [nil, ""],
        do: {key, value}
  end

  defp mount(%{} = table, path) when not is_struct(table) do
    with {:ok, name} <- required(table, "adapter", path),
         {:ok, module} <- adapter(name, path ++ ["adapter"]),
         {:ok, match} <- required(table, "match", path),
         {:ok, match} <- Convert.value(match_type(), match, path ++ ["match"]),
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

  @doc false
  @spec mount_schema() :: keyword()
  def mount_schema do
    [
      adapter: [type: {:in, [:file, :http, :s3]}, required: true],
      match: [type: match_type(), required: true]
    ]
  end

  defp match_type do
    {:or, [{:in, [:path]}, Convert.table(prefix: [type: @rules], scheme: [type: @rules])]}
  end

  @doc false
  @spec adapter_schemas() :: keyword()
  def adapter_schemas do
    [
      file: file_schema(),
      http: http_schema(),
      s3: s3_schema() ++ [buckets: [type: {:map, :string, bucket_type("the S3 settings above")}]]
    ]
  end

  @doc false
  @spec credential_schemas() :: keyword()
  def credential_schemas do
    [static: @static_credentials_schema] ++
      Enum.map(@providers, fn {name, module} ->
        {String.to_atom(name), provider_schema(module)}
      end)
  end

  defp adapter_options(FileSource, table, path), do: Convert.options(table, file_schema(), path)

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

    with {:ok, default} <- Convert.options(table, s3_schema(), path),
         {:ok, buckets} <- s3_buckets(buckets, path ++ ["buckets"]) do
      {:ok, [default: default] ++ buckets}
    end
  end

  defp s3_buckets(nil, _path), do: {:ok, []}

  defp s3_buckets(buckets, path) do
    with {:ok, buckets} <- Convert.value({:map, :string, bucket_type()}, buckets, path),
         do: {:ok, [buckets: buckets]}
  end

  # A bucket overrides the mount's S3 settings.
  defp bucket_type(description \\ nil) do
    {:convert, &Convert.options(&1, s3_schema(), &2), description || s3_schema()}
  end

  defp file_schema, do: with_cache_policy(FileSource.options_schema())

  defp http_schema do
    HTTP.options_schema()
    |> with_cache_policy()
    |> Keyword.merge(
      path_pattern: [type: {:convert, &regex/2, "string (regular expression)"}],
      address_policy: [type: Convert.table(address_policy_schema())],
      request_headers: [type: {:convert, &request_headers/2, "table of string"}],
      bearer_token: [type: {:convert, &bearer_token/2, "string"}]
    )
  end

  # Checked at boot: Req would refuse the request on every fetch instead.
  # Errors name the header but never quote its value.
  @header_name ~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/

  defp request_headers(value, path) do
    with {:ok, headers} <- Convert.value({:map, :string, :string}, value, path) do
      case Enum.find(headers, fn {name, value} -> header_error(name, value) end) do
        nil -> {:ok, headers}
        {name, value} -> {:error, path ++ [name], header_error(name, value)}
      end
    end
  end

  defp header_error(name, value) do
    cond do
      not Regex.match?(@header_name, name) -> "invalid header name"
      String.contains?(value, ["\r", "\n", <<0>>]) -> "invalid header value"
      true -> nil
    end
  end

  defp bearer_token(value, path) do
    case Convert.string(value, path) do
      {:ok, ""} -> {:error, path, "expected a non-empty string"}
      result -> result
    end
  end

  defp s3_schema do
    S3.config_schema()
    |> with_cache_policy()
    |> Keyword.merge(credentials: [type: credentials_type()])
  end

  defp credentials_type do
    {:convert, &credentials/2, "`{ static = {...} }` or `{ provider = \"...\", ... }`"}
  end

  defp with_cache_policy(schema) do
    Keyword.merge(schema, cache_policy: [type: cache_policy_type()])
  end

  @doc false
  @spec cache_policy_type() :: {:convert, function(), keyword()}
  def cache_policy_type, do: Convert.table(CachePolicy.options_schema())

  defp regex(value, path) do
    with {:ok, source} <- Convert.string(value, path) do
      case Regex.compile(source) do
        {:ok, regex} -> {:ok, regex}
        {:error, _reason} -> {:error, path, "invalid regular expression"}
      end
    end
  end

  defp address_policy_schema do
    [allow: [type: {:list, :string}]] ++ Enum.map(@address_categories, &{&1, [type: :boolean]})
  end

  defp credentials(%{"static" => static} = table, path) when map_size(table) == 1 do
    path = path ++ ["static"]

    with {:ok, static} <- Convert.options(static, @static_credentials_schema, path),
         {:ok, static} <- Convert.require_keys(static, [:access_key_id, :secret_access_key], path),
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
      do: Keyword.put(schema, :base, type: credentials_type()),
      else: schema
  end
end
