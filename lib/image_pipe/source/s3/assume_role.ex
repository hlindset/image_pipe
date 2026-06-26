defmodule ImagePipe.Source.S3.AssumeRole do
  @moduledoc """
  Cross-account credential provider via STS `AssumeRole`.

  A composing wrapper: it resolves a **base** provider's credentials, then signs
  an STS `AssumeRole` call with them to obtain temporary credentials for a
  different role (typically in another account).

      credentials:
        {:provider, ImagePipe.Source.S3.AssumeRole,
         base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
         role_arn: "arn:aws:iam::123456789012:role/image-read",
         external_id: "optional-external-id",
         region: "eu-west-1"}

  Options:
    * `:base` — the base credential config (`{:static, …}` or `{:provider, …}`)
      whose credentials are allowed to assume `:role_arn`. **Required.** Resolved
      through `ImagePipe.Source.S3.Credentials.fetch/3`, so the base uses its own
      cache entry.
    * `:role_arn` — ARN of the role to assume. **Required.**
    * `:region` — region for the STS endpoint and SigV4 signing. **Required.**
    * `:external_id` — external ID required by the trust policy (optional).
    * `:role_session_name` — STS session name (default `"image-pipe"`).
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms),
      default 5000.
    * `:plug` — test-only Req plug.

  Both the base resolution and the assumed credentials are cached and refreshed
  by `ImagePipe.Source.S3.RefreshCache` before expiry.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 base: [type: :any, required: true],
                 role_arn: [type: :string, required: true],
                 region: [type: :string, required: true],
                 external_id: [type: :string],
                 role_session_name: [type: :string],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer],
                 plug: [type: :any]
               )

  @impl true
  def validate_options(opts) do
    with {:ok, validated} <- schema_validate(opts),
         {:ok, _base} <- Credentials.validate(Keyword.fetch!(validated, :base)) do
      :ok
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schema_validate(opts), do: NimbleOptions.validate(opts, @opts_schema)

  # do not inspect/log `opts` or `base_credentials` — they carry the base secret
  # key. The STS error is opaque; base creds never appear in an error term.
  @impl true
  def fetch_credentials(scope, opts, _runtime_opts) do
    base = Keyword.fetch!(opts, :base)

    with {:ok, base_credentials} <- Credentials.fetch(scope, base, []) do
      # `external_id` is passed explicitly because `Sts.maybe_put/3` is nil-safe
      # (a nil ExternalId is simply omitted from the form). Everything else
      # optional goes through `Keyword.take`, which OMITS absent keys rather than
      # passing `key: nil` — otherwise an explicit nil would defeat `Sts`'s
      # `Keyword.get(opts, key, default)` for the session name and timeouts.
      Sts.assume_role(
        [
          region: Keyword.fetch!(opts, :region),
          role_arn: Keyword.fetch!(opts, :role_arn),
          external_id: Keyword.get(opts, :external_id),
          base_credentials: base_credentials
        ] ++ Keyword.take(opts, [:role_session_name, :receive_timeout, :connect_timeout, :plug])
      )
    end
  end
end
