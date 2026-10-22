defmodule ImagePipe.Source.S3.CredentialsCacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Source.S3.Credentials

  defmodule CountingProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def validate_options(_opts), do: :ok

    @impl true
    def fetch_credentials(opts) do
      send(Keyword.fetch!(opts, :test), {:fetched, Keyword.fetch!(opts, :id)})

      {:ok, [access_key_id: "AKIA", secret_access_key: "SECRET", token: "TOK"], :never}
    end
  end

  defmodule ExpiryProvider do
    @behaviour ImagePipe.Source.S3.CredentialProvider

    @impl true
    def validate_options(_opts), do: :ok
    @impl true
    def fetch_credentials(opts) do
      {:ok, [access_key_id: "AKIA", secret_access_key: "SECRET"], Keyword.fetch!(opts, :expiry)}
    end
  end

  test "fails closed for expired and malformed provider expiry values" do
    for expiry <- [DateTime.add(DateTime.utc_now(), -60, :second), nil, "tomorrow"] do
      provider = {:provider, ExpiryProvider, [expiry: expiry, test: self()]}
      assert {:error, {:source, :credentials_unavailable}} = Credentials.fetch(provider)
    end
  end

  test "provider results are cached per provider options and normalized" do
    # The RefreshCache is application-global and this suite is async, so
    # `test: self()` keeps these options apart from other tests'.
    provider_a = {:provider, CountingProvider, test: self(), id: :a}
    provider_b = {:provider, CountingProvider, test: self(), id: :b}

    assert {:ok, creds} = Credentials.fetch(provider_a)
    assert creds[:access_key_id] == "AKIA"
    assert creds[:token] == "TOK"
    assert_received {:fetched, :a}

    assert {:ok, _} = Credentials.fetch(provider_a)
    refute_received {:fetched, :a}

    assert {:ok, _} = Credentials.fetch(provider_b)
    assert_received {:fetched, :b}
  end

  test "credential cache process names do not expose provider secrets" do
    secret = "fake-provider-secret-#{System.unique_integer([:positive])}"
    provider = {:provider, CountingProvider, [test: self(), id: :secret, secret: secret]}
    assert {:ok, _} = Credentials.fetch(provider)

    keys =
      Registry.select(ImagePipe.Source.S3.RefreshCache.Registry, [
        {{:"$1", :_, :_}, [], [:"$1"]}
      ])

    refute inspect(keys, limit: :infinity) =~ secret
  end

  test "fails closed as :credentials_unavailable when the provider errors" do
    defmodule FailingProvider do
      @behaviour ImagePipe.Source.S3.CredentialProvider

      @impl true
      def validate_options(_opts), do: :ok
      @impl true
      def fetch_credentials(_opts), do: {:error, :nope}
    end

    provider = {:provider, FailingProvider, [secret: "fake-option-secret", test: self()]}

    log =
      capture_log(fn ->
        assert {:error, {:source, :credentials_unavailable}} = Credentials.fetch(provider)
      end)

    assert log =~
             "S3 credentials from #{inspect(FailingProvider)} could not be fetched: :nope"

    refute log =~ "fake-option-secret"
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

    plug = fn conn ->
      send(test, :sts_called)
      Plug.Conn.send_resp(conn, 200, xml)
    end

    provider =
      {:provider, ImagePipe.Source.S3.AssumeRole,
       base: {:static, [access_key_id: "AKIABASE", secret_access_key: "SK"]},
       role_arn: "arn:aws:iam::1:role/x",
       region: "us-east-1",
       plug: plug}

    assert {:ok, creds} = Credentials.fetch(provider)
    assert creds[:access_key_id] == "ASIAX"
    assert creds[:token] == "tx"
    assert_received :sts_called

    # cached: no second STS call for the same options
    assert {:ok, _} = Credentials.fetch(provider)
    refute_received :sts_called
  end
end
