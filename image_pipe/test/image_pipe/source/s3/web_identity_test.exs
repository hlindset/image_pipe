defmodule ImagePipe.Source.S3.WebIdentityTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.WebIdentity

  @xml ~s(<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>ASIAEKS</AccessKeyId><SecretAccessKey>eksSecret</SecretAccessKey><SessionToken>eksSession</SessionToken><Expiration>2026-06-26T14:00:00Z</Expiration></Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>)

  @tag :tmp_dir
  test "reads the token file and exchanges it for credentials", %{tmp_dir: tmp_dir} do
    token_path = Path.join(tmp_dir, "token")
    File.write!(token_path, "OIDC-TOKEN-CONTENTS\n")

    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sts_body, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, @xml)
    end

    opts = [
      token_file: token_path,
      role_arn: "arn:aws:iam::123456789012:role/eks",
      region: "eu-west-1",
      plug: plug
    ]

    assert {:ok, creds, expiry} = WebIdentity.fetch_credentials("my-bucket", opts, [])
    assert creds[:access_key_id] == "ASIAEKS"
    assert creds[:token] == "eksSession"
    assert expiry == ~U[2026-06-26 14:00:00Z]

    assert_received {:sts_body, body, headers}
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRoleWithWebIdentity"
    # token file contents are trimmed and sent in the body
    assert params["WebIdentityToken"] == "OIDC-TOKEN-CONTENTS"
    # unsigned
    assert [] == for({k, _v} <- headers, k == "authorization", do: :found)
  end

  @tag :tmp_dir
  test "re-reads the token file on each fetch (rotation)", %{tmp_dir: tmp_dir} do
    token_path = Path.join(tmp_dir, "token")
    File.write!(token_path, "FIRST")
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token, URI.decode_query(body)["WebIdentityToken"]})
      Plug.Conn.send_resp(conn, 200, @xml)
    end

    opts = [token_file: token_path, role_arn: "arn:x", region: "us-east-1", plug: plug]

    assert {:ok, _, _} = WebIdentity.fetch_credentials("b", opts, [])
    assert_received {:token, "FIRST"}

    File.write!(token_path, "SECOND")
    assert {:ok, _, _} = WebIdentity.fetch_credentials("b", opts, [])
    assert_received {:token, "SECOND"}
  end

  test "errors when the token file is missing" do
    opts = [token_file: "/no/such/token", role_arn: "arn:x", region: "us-east-1"]

    assert {:error, :web_identity_token_unreadable} =
             WebIdentity.fetch_credentials("b", opts, [])
  end

  test "validate_options requires token_file, role_arn, and region" do
    assert :ok =
             WebIdentity.validate_options(
               token_file: "/var/run/token",
               role_arn: "arn:x",
               region: "us-east-1"
             )

    assert {:error, _} = WebIdentity.validate_options(role_arn: "arn:x", region: "us-east-1")
    assert {:error, _} = WebIdentity.validate_options(token_file: "/t", region: "us-east-1")
    assert {:error, _} = WebIdentity.validate_options(token_file: "/t", role_arn: "arn:x")
  end
end
