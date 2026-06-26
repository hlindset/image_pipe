defmodule ImagePipe.Source.S3.ContainerCredentialsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.ContainerCredentials

  @creds_json ~s({"AccessKeyId":"AKIAECS","SecretAccessKey":"shh","Token":"sess","Expiration":"2026-06-26T12:00:00Z"})

  test "fetches from the full URI and sends the auth token" do
    plug = fn conn ->
      assert conn.request_path == "/creds"
      assert ["Bearer abc"] = Plug.Conn.get_req_header(conn, "authorization")
      Plug.Conn.send_resp(conn, 200, @creds_json)
    end

    opts = [full_uri: "http://169.254.170.2/creds", auth_token: "Bearer abc", plug: plug]

    assert {:ok, creds, expiry} = ContainerCredentials.fetch_credentials("b", opts, [])
    assert creds[:access_key_id] == "AKIAECS"
    assert creds[:token] == "sess"
    assert expiry == ~U[2026-06-26 12:00:00Z]
  end

  test "joins the relative URI to the ECS base" do
    plug = fn conn ->
      assert conn.request_path == "/v2/credentials/abc"
      Plug.Conn.send_resp(conn, 200, @creds_json)
    end

    opts = [relative_uri: "/v2/credentials/abc", plug: plug]
    assert {:ok, _creds, _expiry} = ContainerCredentials.fetch_credentials("b", opts, [])
  end

  test "errors when no URI is configured" do
    assert {:error, :container_uri_missing} =
             ContainerCredentials.fetch_credentials("b", [], [])
  end

  test "returns an error on malformed credentials JSON" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "not json") end
    opts = [full_uri: "http://169.254.170.2/creds", plug: plug]

    assert {:error, :container_invalid_credentials} =
             ContainerCredentials.fetch_credentials("b", opts, [])
  end

  test "validate_options enforces the full_uri loopback/https guard" do
    assert {:error, _message} =
             ContainerCredentials.validate_options(full_uri: "http://evil.example/creds")

    assert :ok = ContainerCredentials.validate_options(full_uri: "https://creds.example/x")
    assert :ok = ContainerCredentials.validate_options(full_uri: "http://169.254.170.2/creds")
    assert :ok = ContainerCredentials.validate_options(relative_uri: "/v2/credentials/abc")
    assert {:error, _message} = ContainerCredentials.validate_options(bogus: 1)
  end
end
