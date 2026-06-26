defmodule ImagePipe.Source.S3.WebIdentity do
  @moduledoc """
  EKS/IRSA credential provider via STS `AssumeRoleWithWebIdentity`.

  On EKS with IAM Roles for Service Accounts (IRSA), the cluster projects a
  short-lived OIDC token into the pod and injects `AWS_WEB_IDENTITY_TOKEN_FILE`
  and `AWS_ROLE_ARN`. This provider reads that token file and exchanges it for
  temporary credentials with an **unsigned** STS call (the token is the auth).

      credentials:
        {:provider, ImagePipe.Source.S3.WebIdentity,
         token_file: System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
         role_arn: System.get_env("AWS_ROLE_ARN"),
         region: System.get_env("AWS_REGION")}

  Options:
    * `:token_file` — path to the projected OIDC token. **Required.** Re-read on
      every refresh, because the projected token rotates. The path is the
      cluster's projected-volume symlink; following it is intentional.
    * `:role_arn` — ARN of the role to assume. **Required.**
    * `:region` — region for the STS endpoint. **Required.**
    * `:role_session_name` — STS session name (default `"image-pipe"`).
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms),
      default 5000.
    * `:plug` — test-only Req plug.

  Results are cached and refreshed by `ImagePipe.Source.S3.RefreshCache`.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 token_file: [type: :string, required: true],
                 role_arn: [type: :string, required: true],
                 region: [type: :string, required: true],
                 role_session_name: [type: :string],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer],
                 plug: [type: :any]
               )

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # do not inspect/log `opts` or `token` — the OIDC token is a bearer credential.
  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, token} <- read_token(Keyword.fetch!(opts, :token_file)) do
      Sts.assume_role_with_web_identity(
        [
          region: Keyword.fetch!(opts, :region),
          role_arn: Keyword.fetch!(opts, :role_arn),
          web_identity_token: token
        ] ++ Keyword.take(opts, [:role_session_name, :receive_timeout, :connect_timeout, :plug])
      )
    end
  end

  defp read_token(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:error, :web_identity_token_unreadable}
          token -> {:ok, token}
        end

      {:error, _reason} ->
        {:error, :web_identity_token_unreadable}
    end
  end
end
