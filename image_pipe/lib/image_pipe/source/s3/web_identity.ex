defmodule ImagePipe.Source.S3.WebIdentity do
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 token_file: [
                   type: :string,
                   required: true,
                   doc: """
                   Path of the web identity token, from \
                   `AWS_WEB_IDENTITY_TOKEN_FILE`. The file is read again on every \
                   refresh, since the platform rotates it.
                   """
                 ],
                 role_arn: [
                   type: :string,
                   required: true,
                   doc: "ARN of the role to assume, from `AWS_ROLE_ARN`."
                 ],
                 region: [
                   type: :string,
                   required: true,
                   doc: "Region of the STS endpoint, `sts.<region>.amazonaws.com`."
                 ],
                 role_session_name: [
                   type: :string,
                   doc:
                     "Session name for the assumed role. The default value is `\"image-pipe\"`."
                 ],
                 receive_timeout: [
                   type: :non_neg_integer,
                   doc: "Milliseconds to wait for each response. The default value is `5000`."
                 ],
                 connect_timeout: [
                   type: :non_neg_integer,
                   doc: "Milliseconds to wait for a connection. The default value is `5000`."
                 ],
                 plug: [type: :any, doc: false]
               )

  @moduledoc """
  Credential provider for EKS IAM roles for service accounts (IRSA), using
  STS `AssumeRoleWithWebIdentity`.

      credentials:
        {:provider, ImagePipe.Source.S3.WebIdentity,
         token_file: System.fetch_env!("AWS_WEB_IDENTITY_TOKEN_FILE"),
         role_arn: System.fetch_env!("AWS_ROLE_ARN"),
         region: System.fetch_env!("AWS_REGION")}

  It exchanges the token the cluster mounts into the pod for temporary
  credentials. The STS call is unsigned, since the token authenticates it.
  Setting up credentials is covered in
  [Serving images from S3](serving-from-s3.md#choose-credentials).

  ## Options

  #{NimbleOptions.docs(@opts_schema)}
  """

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # do not inspect/log `opts` or `token` — the OIDC token is a bearer credential.
  @impl true
  def fetch_credentials(_scope, opts) do
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

  @doc false
  def options_schema, do: @opts_schema.schema
end
