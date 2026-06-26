defmodule ImagePipe.Source.S3.CredentialProvider do
  @moduledoc """
  Behaviour for host-pluggable S3 credential providers.

  A provider resolves temporary or permanent AWS credentials for a given scope
  (the bucket name). It is selected via the source config:

      credentials: {:provider, MyApp.S3.InstanceRole, []}

  Results are cached by `ImagePipe.Source.S3.RefreshCache` keyed by
  `{provider, opts, scope}`, so `fetch_credentials/3` is invoked once per
  credential lifetime, not per request. Because results are cached across
  requests, the provider MUST derive its behaviour from `scope` and `opts` only;
  `runtime_opts` is reserved and is currently passed as `[]`.

  The returned `expiry` is a `DateTime.t()` for temporary credentials (the cache
  refreshes shortly before it) or `:never` for permanent credentials (cached for
  the process lifetime, never refreshed).
  """

  @type scope :: String.t()
  @type credentials :: keyword()
  @type expiry :: DateTime.t() | :never

  @callback fetch_credentials(scope(), keyword(), keyword()) ::
              {:ok, credentials(), expiry()} | {:error, term()}

  @doc """
  Validate host-supplied provider options at config time. Optional; when
  implemented, `ImagePipe.Source.S3.Credentials.validate/1` calls it during
  source-config validation so malformed options fail at startup, not per request.
  """
  @callback validate_options(keyword()) :: :ok | {:error, term()}

  @optional_callbacks validate_options: 1
end
