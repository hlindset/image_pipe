defmodule ImagePipe.Source.S3.CredentialProvider do
  @moduledoc """
  Behaviour for host-pluggable S3 credential providers.

  A provider resolves temporary or permanent AWS credentials for a given scope
  (the bucket name). It is selected via the source config:

      credentials: {:provider, MyApp.S3.InstanceRole, []}

  Results are cached by `ImagePipe.Source.S3.RefreshCache` keyed by
  `{provider, opts, scope}` and reused across requests. Entries are checked
  every five minutes and retire after a full check interval without a request,
  once any in-flight fetch completes; a later request fetches credentials again. Because
  results are cached across requests, the provider MUST derive its behaviour
  from `scope` and `opts` only;
  `runtime_opts` is reserved and is currently passed as `[]`.

  The returned `expiry` is a `DateTime.t()` for temporary credentials (the cache
  refreshes shortly before it) or `:never` for permanent credentials (cached for
  the entry lifetime, never refreshed).
  Invalid expiry values and results that have expired by the time the fetch
  completes are rejected. A failed refresh can retain previously cached
  credentials only while those credentials are still unexpired.
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
