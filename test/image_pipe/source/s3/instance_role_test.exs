defmodule ImagePipe.Source.S3.InstanceRoleTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.InstanceRole

  # A Req plug emulating IMDSv2: token PUT, role listing, creds GET.
  defp imds_plug(creds_json) do
    fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          assert ["21600"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token-ttl-seconds")

          Plug.Conn.send_resp(conn, 200, "session-token-xyz")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          assert ["session-token-xyz"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token")

          Plug.Conn.send_resp(conn, 200, "image-server-role")

        {"GET", "/latest/meta-data/iam/security-credentials/image-server-role"} ->
          assert ["session-token-xyz"] =
                   Plug.Conn.get_req_header(conn, "x-aws-ec2-metadata-token")

          Plug.Conn.send_resp(conn, 200, creds_json)
      end
    end
  end

  test "fetches temporary credentials via IMDSv2 and parses the expiry" do
    creds_json =
      ~s({"Code":"Success","AccessKeyId":"AKIAIMDS","SecretAccessKey":"shh","Token":"sess","Expiration":"2026-06-26T12:00:00Z"})

    opts = [plug: imds_plug(creds_json)]

    assert {:ok, creds, expiry} = InstanceRole.fetch_credentials("any-bucket", opts, [])
    assert creds[:access_key_id] == "AKIAIMDS"
    assert creds[:secret_access_key] == "shh"
    assert creds[:token] == "sess"
    assert expiry == ~U[2026-06-26 12:00:00Z]
  end

  test "returns an error when IMDS is unreachable" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end

    assert {:error, :imds_token_unavailable} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "returns an error when no role is attached to the instance" do
    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          Plug.Conn.send_resp(conn, 200, "tok")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          Plug.Conn.send_resp(conn, 404, "")
      end
    end

    assert {:error, :imds_no_role} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "returns an error on malformed credentials JSON" do
    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          Plug.Conn.send_resp(conn, 200, "t")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          Plug.Conn.send_resp(conn, 200, "role")

        {"GET", "/latest/meta-data/iam/security-credentials/role"} ->
          Plug.Conn.send_resp(conn, 200, "not json")
      end
    end

    assert {:error, :imds_invalid_credentials} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "parses a fractional-second expiration" do
    creds_json =
      ~s({"Code":"Success","AccessKeyId":"AK","SecretAccessKey":"s","Token":"t","Expiration":"2026-06-26T12:00:00.123Z"})

    plug = fn conn ->
      case {conn.method, conn.request_path} do
        {"PUT", "/latest/api/token"} ->
          Plug.Conn.send_resp(conn, 200, "tok")

        {"GET", "/latest/meta-data/iam/security-credentials/"} ->
          Plug.Conn.send_resp(conn, 200, "role")

        {"GET", "/latest/meta-data/iam/security-credentials/role"} ->
          Plug.Conn.send_resp(conn, 200, creds_json)
      end
    end

    assert {:ok, _creds, ~U[2026-06-26 12:00:00.123Z]} =
             InstanceRole.fetch_credentials("b", [plug: plug], [])
  end

  test "validate_options rejects unknown options and accepts known ones" do
    assert {:error, _message} = InstanceRole.validate_options(bogus: 1)
    assert :ok = InstanceRole.validate_options(ttl_seconds: 900)
  end
end
