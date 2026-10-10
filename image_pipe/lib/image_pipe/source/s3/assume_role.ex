defmodule ImagePipe.Source.S3.AssumeRole do
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 base: [
                   type: :any,
                   type_doc: "`{:static, keyword()}` or `{:provider, module(), keyword()}`",
                   required: true,
                   doc: """
                   Credentials allowed to assume `:role_arn`, in any form the \
                   `:credentials` option of `ImagePipe.Source.S3` takes. They are \
                   cached and refreshed separately.
                   """
                 ],
                 role_arn: [type: :string, required: true, doc: "ARN of the role to assume."],
                 region: [
                   type: :string,
                   required: true,
                   doc: """
                   Region of the STS endpoint, `sts.<region>.amazonaws.com`, also \
                   used to sign the call.
                   """
                 ],
                 external_id: [
                   type: :string,
                   doc: "External ID that the role's trust policy requires."
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
  Credential provider that assumes an IAM role with STS `AssumeRole`, usually
  a role in another account.

      credentials:
        {:provider, ImagePipe.Source.S3.AssumeRole,
         base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
         role_arn: "arn:aws:iam::123456789012:role/image-read",
         region: "eu-west-1"}

  It signs the STS call with the `:base` credentials. Setting up credentials
  is covered in [Serving images from S3](serving-from-s3.md#choose-credentials).

  ## Options

  #{NimbleOptions.docs(@opts_schema)}
  """

  @doc false
  def options_schema, do: @opts_schema.schema

  @impl true
  def validate_options(opts) do
    with {:ok, validated} <- schema_validate(opts),
         {:ok, _base} <- Credentials.validate(Keyword.fetch!(validated, :base)) do
      :ok
    else
      {:error, %NimbleOptions.ValidationError{} = error} ->
        {:error, Exception.message(error)}

      # Credentials.validate/1 already tags a bad base as
      # {:invalid_source_config, reason}; unwrap it so the outer
      # Credentials.validate/1 (which re-wraps a provider's {:error, reason})
      # doesn't double-nest the tag.
      {:error, {:invalid_source_config, reason}} ->
        {:error, reason}
    end
  end

  defp schema_validate(opts), do: NimbleOptions.validate(opts, @opts_schema)

  # do not inspect/log `opts` or `base_credentials` — they carry the base secret
  # key. The STS error is opaque; base creds never appear in an error term.
  @impl true
  def fetch_credentials(scope, opts) do
    base = Keyword.fetch!(opts, :base)

    with {:ok, base_credentials} <- Credentials.fetch(scope, base) do
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
