if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.Source.S3.StsLocalstackTest do
    @moduledoc """
    Opt-in protocol-fidelity smoke test against a real LocalStack STS, provisioned
    self-containedly via testcontainers. NOT a correctness gate — LocalStack does
    not strictly verify SigV4 (signing is proven by the live S3 GET path); this
    only confirms a real AWS-compatible server accepts our `AssumeRole` /
    `AssumeRoleWithWebIdentity` request shapes and returns parseable XML.

    How to run (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Compiled only when `testcontainers` is present (`AWS_INTEGRATION`/`IMGPROXY_DIFF`)
    and tagged `:aws_integration` (excluded from the default lane), so a normal
    `mix test` never touches it.
    """
    use ExUnit.Case, async: false

    @moduletag :aws_integration

    alias ImagePipe.Source.S3.Sts
    alias ImagePipe.SourceTest.S3.IntegrationContainers

    setup_all do
      IntegrationContainers.ensure_started()
      endpoint = IntegrationContainers.start_localstack_sts() <> "/"
      %{endpoint: endpoint}
    end

    test "AssumeRole round-trips against LocalStack STS", %{endpoint: endpoint} do
      # LocalStack accepts any credentials and returns the standard STS XML
      # <Credentials> shape, exercising the real HTTP POST + XML parse path.
      # `:endpoint_override` targets the container; the signing region stays a
      # normal value.
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe",
                 base_credentials: [access_key_id: "test", secret_access_key: "test"],
                 endpoint_override: endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:secret_access_key])
      assert is_binary(creds[:token])
    end

    test "AssumeRoleWithWebIdentity round-trips against LocalStack STS", %{endpoint: endpoint} do
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role_with_web_identity(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe-eks",
                 web_identity_token: "localstack-accepts-anything",
                 endpoint_override: endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:token])
    end
  end
end
