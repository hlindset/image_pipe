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
end
