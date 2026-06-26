defmodule ImagePipe.Source.S3.StsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.Sts

  # A representative real STS AssumeRole response. The wire format sends compact
  # element values (the AWS docs pretty-print the SessionToken across lines for
  # readability; the actual response does not), so this fixture keeps values on
  # one line — matching what the parser sees in production.
  @assume_role_xml ~s(<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleResult><AssumedRoleUser><Arn>arn:aws:sts::123456789012:assumed-role/demo/image-pipe</Arn><AssumedRoleId>ARO123EXAMPLE123:image-pipe</AssumedRoleId></AssumedRoleUser><Credentials><AccessKeyId>ASIAIOSFODNN7EXAMPLE</AccessKeyId><SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY</SecretAccessKey><SessionToken>AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==</SessionToken><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials><PackedPolicySize>6</PackedPolicySize></AssumeRoleResult><ResponseMetadata><RequestId>c6104cbe-af31-11e0-8154-cbc7ccf896c7</RequestId></ResponseMetadata></AssumeRoleResponse>)

  @web_identity_xml ~s(<AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleWithWebIdentityResult><SubjectFromWebIdentityToken>sub-123</SubjectFromWebIdentityToken><Audience>sts.amazonaws.com</Audience><AssumedRoleUser><Arn>arn:aws:sts::123456789012:assumed-role/eks/image-pipe</Arn><AssumedRoleId>ARO456:image-pipe</AssumedRoleId></AssumedRoleUser><Credentials><AccessKeyId>ASIAEKSEXAMPLE</AccessKeyId><SecretAccessKey>eksSecretEXAMPLEKEY</SecretAccessKey><SessionToken>eksSessionTokenEXAMPLE==</SessionToken><Expiration>2026-06-26T14:00:00Z</Expiration></Credentials><Provider>arn:aws:iam::123456789012:oidc-provider/oidc.eks</Provider></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>)

  test "extracts the four credential fields from an AssumeRole response" do
    assert {:ok, creds, expiry} = Sts.parse_credentials(@assume_role_xml)
    assert creds[:access_key_id] == "ASIAIOSFODNN7EXAMPLE"
    assert creds[:secret_access_key] == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY"
    assert creds[:token] =~ "AQoDYXdzEPT"
    assert expiry == ~U[2026-06-26 13:34:41Z]
  end

  test "extracts credentials from an AssumeRoleWithWebIdentity response (same shape)" do
    assert {:ok, creds, expiry} = Sts.parse_credentials(@web_identity_xml)
    assert creds[:access_key_id] == "ASIAEKSEXAMPLE"
    assert creds[:token] == "eksSessionTokenEXAMPLE=="
    assert expiry == ~U[2026-06-26 14:00:00Z]
  end

  test "errors on a malformed/error STS response with no Credentials element" do
    error_xml =
      ~s(<ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><Error><Type>Sender</Type><Code>AccessDenied</Code><Message>Not authorized to perform sts:AssumeRole</Message></Error></ErrorResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(error_xml)
  end

  test "errors when a required field is missing from Credentials" do
    missing =
      ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>s</SecretAccessKey><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(missing)
  end

  test "errors on a non-ISO8601 expiration" do
    bad =
      ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>s</SecretAccessKey><SessionToken>t</SessionToken><Expiration>not-a-date</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(bad)
  end

  # A Req plug that captures the request and replies with the recorded success.
  defp ok_plug(capture_pid, body \\ nil) do
    response = body || @assume_role_xml

    fn conn ->
      {:ok, req_body, conn} = Plug.Conn.read_body(conn)
      send(capture_pid, {:sts_request, conn.method, conn.request_path, conn.req_headers, req_body})
      Plug.Conn.send_resp(conn, 200, response)
    end
  end

  test "assume_role signs the POST and form-encodes Action/RoleArn/RoleSessionName" do
    base = [access_key_id: "AKIABASE", secret_access_key: "BASESECRET", token: "BASESESSION"]

    opts = [
      region: "eu-west-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      role_session_name: "image-pipe",
      external_id: "ext-42",
      base_credentials: base,
      plug: ok_plug(self())
    ]

    assert {:ok, creds, _expiry} = Sts.assume_role(opts)
    assert creds[:access_key_id] == "ASIAIOSFODNN7EXAMPLE"

    assert_received {:sts_request, "POST", "/", headers, body}

    # SigV4-signed with the base credentials and the :sts service.
    auth = header(headers, "authorization")
    assert auth =~ "AWS4-HMAC-SHA256"
    assert auth =~ "/sts/aws4_request"
    assert auth =~ "Credential=AKIABASE/"
    # the base session token is forwarded as the security-token header
    assert ["BASESESSION"] = value_list(headers, "x-amz-security-token")
    assert header(headers, "content-type") =~ "application/x-www-form-urlencoded"

    # form body carries the AssumeRole action + parameters
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRole"
    assert params["Version"] == "2011-06-15"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/demo"
    assert params["RoleSessionName"] == "image-pipe"
    assert params["ExternalId"] == "ext-42"
  end

  test "assume_role omits ExternalId when not configured and defaults the session name" do
    base = [access_key_id: "AKIABASE", secret_access_key: "BASESECRET"]

    opts = [
      region: "us-east-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      base_credentials: base,
      plug: ok_plug(self())
    ]

    assert {:ok, _creds, _expiry} = Sts.assume_role(opts)
    assert_received {:sts_request, "POST", "/", _headers, body}
    params = URI.decode_query(body)
    refute Map.has_key?(params, "ExternalId")
    assert params["RoleSessionName"] == "image-pipe"
  end

  test "assume_role_with_web_identity POSTs unsigned with the token in the body" do
    opts = [
      region: "eu-west-1",
      role_arn: "arn:aws:iam::123456789012:role/eks",
      role_session_name: "image-pipe",
      web_identity_token: "OIDC.TOKEN.VALUE",
      plug: ok_plug(self(), @web_identity_xml)
    ]

    assert {:ok, creds, _expiry} = Sts.assume_role_with_web_identity(opts)
    assert creds[:access_key_id] == "ASIAEKSEXAMPLE"

    assert_received {:sts_request, "POST", "/", headers, body}
    # UNSIGNED: no SigV4 Authorization header
    assert header(headers, "authorization") == nil

    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRoleWithWebIdentity"
    assert params["Version"] == "2011-06-15"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/eks"
    assert params["WebIdentityToken"] == "OIDC.TOKEN.VALUE"
  end

  test "maps an STS non-200 to an error" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 403, "<ErrorResponse/>") end

    opts = [
      region: "us-east-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      base_credentials: [access_key_id: "AK", secret_access_key: "SK"],
      plug: plug
    ]

    assert {:error, :sts_request_failed} = Sts.assume_role(opts)
  end

  defp header(headers, name) do
    case value_list(headers, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp value_list(headers, name), do: for({k, v} <- headers, k == name, do: v)
end
