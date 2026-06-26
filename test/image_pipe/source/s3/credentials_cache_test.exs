defmodule ImagePipe.Source.S3.CredentialsCacheTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.Credentials

  defmodule CountingProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def fetch_credentials(scope, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test), {:fetched, scope})

      {:ok, [access_key_id: "AKIA", secret_access_key: "SECRET", token: "TOK"], :never}
    end
  end

  test "provider results are cached per scope and normalized" do
    opts = [test: self()]
    provider = {:provider, CountingProvider, opts}
    # the RefreshCache is application-global and this suite is async: true, so
    # scopes MUST be unique per test or assert/refute_received pass tautologically.
    bucket_a = "bucket-a-#{System.unique_integer([:positive])}"
    bucket_b = "bucket-b-#{System.unique_integer([:positive])}"

    assert {:ok, creds} = Credentials.fetch(bucket_a, provider, [])
    assert creds[:access_key_id] == "AKIA"
    assert creds[:token] == "TOK"
    assert_received {:fetched, ^bucket_a}

    # cached: no second fetch for the same scope
    assert {:ok, _} = Credentials.fetch(bucket_a, provider, [])
    refute_received {:fetched, ^bucket_a}

    # different scope → separate entry → fetched
    assert {:ok, _} = Credentials.fetch(bucket_b, provider, [])
    assert_received {:fetched, ^bucket_b}
  end

  test "fails closed as :credentials_unavailable when the provider errors" do
    defmodule FailingProvider do
      @behaviour ImagePipe.Source.S3.CredentialProvider
      @impl true
      def fetch_credentials(_scope, _opts, _runtime), do: {:error, :nope}
    end

    provider = {:provider, FailingProvider, []}

    assert {:error, {:source, :credentials_unavailable}} =
             Credentials.fetch("bucket-c-#{System.unique_integer()}", provider, [])
  end

  test "AssumeRole provider routes through the cache and normalizes" do
    # Expiry must be in the future relative to *now*: this goes through the
    # RefreshCache, whose freshness check would otherwise treat a past expiry as
    # stale and re-fetch, defeating the cache-hit assertion below.
    expiration =
      DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.to_iso8601()

    xml =
      "<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIAX</AccessKeyId><SecretAccessKey>sx</SecretAccessKey><SessionToken>tx</SessionToken><Expiration>#{expiration}</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>"

    test = self()
    scope = "assume-#{System.unique_integer([:positive])}"

    plug = fn conn ->
      send(test, {:sts_called, scope})
      Plug.Conn.send_resp(conn, 200, xml)
    end

    provider =
      {:provider, ImagePipe.Source.S3.AssumeRole,
       base: {:static, [access_key_id: "AKIABASE", secret_access_key: "SK"]},
       role_arn: "arn:aws:iam::1:role/x",
       region: "us-east-1",
       plug: plug}

    assert {:ok, creds} = Credentials.fetch(scope, provider, [])
    assert creds[:access_key_id] == "ASIAX"
    assert creds[:token] == "tx"
    assert_received {:sts_called, ^scope}

    # cached: no second STS call for the same scope
    assert {:ok, _} = Credentials.fetch(scope, provider, [])
    refute_received {:sts_called, ^scope}
  end
end
