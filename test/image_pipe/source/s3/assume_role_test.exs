defmodule ImagePipe.Source.S3.AssumeRoleTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.AssumeRole

  # A static base so the test does not depend on IMDS/ECS. The provider resolves
  # the base through Credentials.fetch/3 regardless of base shape.
  @base {:static, [access_key_id: "AKIABASE", secret_access_key: "BASESECRET"]}

  @assume_role_xml ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIAASSUMED</AccessKeyId><SecretAccessKey>assumedSecret</SecretAccessKey><SessionToken>assumedSession</SessionToken><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

  defmodule FailingBase do
    @behaviour ImagePipe.Source.S3.CredentialProvider
    @impl true
    def fetch_credentials(_scope, _opts, _runtime), do: {:error, :no_base}
  end

  defp sts_plug(capture) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(capture, {:sts_body, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, @assume_role_xml)
    end
  end

  test "resolves base credentials and exchanges them for assumed-role credentials" do
    opts = [
      base: @base,
      role_arn: "arn:aws:iam::123456789012:role/demo",
      region: "eu-west-1",
      plug: sts_plug(self())
    ]

    assert {:ok, creds, expiry} = AssumeRole.fetch_credentials("my-bucket", opts, [])
    assert creds[:access_key_id] == "ASIAASSUMED"
    assert creds[:secret_access_key] == "assumedSecret"
    assert creds[:token] == "assumedSession"
    assert expiry == ~U[2026-06-26 13:34:41Z]

    assert_received {:sts_body, body, headers}
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRole"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/demo"
    # signed with the resolved base key
    auth = for({k, v} <- headers, k == "authorization", do: v) |> List.first()
    assert auth =~ "Credential=AKIABASE/"
  end

  test "fails when the base credentials cannot be resolved" do
    opts = [
      base: {:provider, FailingBase, []},
      role_arn: "arn:aws:iam::123456789012:role/demo",
      region: "eu-west-1"
    ]

    assert {:error, _reason} =
             AssumeRole.fetch_credentials("bkt-#{System.unique_integer([:positive])}", opts, [])
  end

  test "validate_options requires role_arn and region and validates the base" do
    assert :ok =
             AssumeRole.validate_options(
               base: @base,
               role_arn: "arn:aws:iam::1:role/x",
               region: "us-east-1"
             )

    assert {:error, _} = AssumeRole.validate_options(base: @base, region: "us-east-1")
    assert {:error, _} = AssumeRole.validate_options(base: @base, role_arn: "arn:x")

    assert {:error, _} =
             AssumeRole.validate_options(
               base: {:static, []},
               role_arn: "arn:x",
               region: "us-east-1"
             )
  end
end
