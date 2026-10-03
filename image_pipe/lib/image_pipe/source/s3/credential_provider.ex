defmodule ImagePipe.Source.S3.CredentialProvider do
  @moduledoc """
  Behaviour for S3 credential providers.

  A provider fetches AWS credentials for a bucket. Select it in the
  `:credentials` setting of `ImagePipe.Source.S3`:

      credentials: {:provider, MyApp.VaultCredentials, path: "aws/creds/image-read"}

  ImagePipe caches each result per provider, options, and bucket, and shares
  it across requests. Temporary credentials are refreshed five minutes before
  they expire. A cache entry is dropped after at least five minutes without a
  request, and the next request fetches again. The built-in providers are listed under
  [Credentials](`m:ImagePipe.Source.S3#module-credentials`).
  """

  @type scope :: String.t()
  @type credentials :: keyword()
  @type expiry :: DateTime.t() | :never

  @doc """
  Fetches credentials for `scope`, the bucket name.

  Returns a keyword list with `:access_key_id`, `:secret_access_key`, and an
  optional `:token`, and an expiry: a `DateTime` for temporary credentials,
  or `:never`. A result that has already expired, or any other expiry, is
  rejected. When a refresh fails, the previous credentials are used until
  they expire.

  The result is shared by every request for the bucket, so it must depend
  only on `scope` and the options. The third argument is always `[]`.
  """
  @callback fetch_credentials(scope(), keyword(), keyword()) ::
              {:ok, credentials(), expiry()} | {:error, term()}

  @doc """
  Checks the provider's options when the source is configured, so bad options
  fail at startup instead of on the first request. Optional.
  """
  @callback validate_options(keyword()) :: :ok | {:error, term()}

  @optional_callbacks validate_options: 1
end
