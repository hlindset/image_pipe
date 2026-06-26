defmodule ImagePipe.Source.S3.StsLocalstackTest do
  # Opt-in protocol-fidelity smoke test against a real LocalStack STS. NOT a
  # correctness gate (LocalStack does not strictly verify SigV4 — signing is
  # already proven by the live S3 GET path); it only confirms a real
  # AWS-compatible server accepts our request shapes and returns parseable XML.
  #
  # Bring up LocalStack yourself and point this lane at it (no testcontainers
  # coupling — that dep only exists under IMGPROXY_DIFF):
  #
  #   docker run --rm -p 4566:4566 -e SERVICES=sts localstack/localstack:3
  #   STS_LOCALSTACK_ENDPOINT=http://localhost:4566/ \
  #     mise exec -- mix test --include aws_integration \
  #       test/image_pipe/source/s3/sts_localstack_test.exs
  #
  # When STS_LOCALSTACK_ENDPOINT is unset the module compiles to zero tests, so a
  # normal run never touches it (and the :aws_integration tag excludes it anyway).
  use ExUnit.Case, async: false

  @moduletag :aws_integration

  @endpoint System.get_env("STS_LOCALSTACK_ENDPOINT")

  if @endpoint do
    alias ImagePipe.Source.S3.Sts

    test "AssumeRole round-trips against LocalStack STS" do
      # LocalStack accepts any credentials and returns the standard STS XML
      # <Credentials> shape, so this exercises the real HTTP POST + XML parse
      # path end-to-end. `:endpoint_override` targets the container while the
      # signing region stays a normal value.
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe",
                 base_credentials: [access_key_id: "test", secret_access_key: "test"],
                 endpoint_override: @endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:secret_access_key])
      assert is_binary(creds[:token])
    end

    test "AssumeRoleWithWebIdentity round-trips against LocalStack STS" do
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role_with_web_identity(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe-eks",
                 web_identity_token: "localstack-accepts-anything",
                 endpoint_override: @endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:token])
    end
  end
end
