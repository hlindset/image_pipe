defmodule ImagePipe.Source.S3Test do
  use ExUnit.Case, async: false

  alias ImagePipe.Plan.Source.Object
  alias ImagePipe.Source
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response
  alias ImagePipe.Source.S3
  alias ImagePipe.SourceTest.CredentialProvider

  test "s3 revision is stable under auto mode" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ]
             )

    source = %Object{adapter: :s3, scope: "bucket", key: "cat.jpg", revision: "v1"}

    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert resolved.internal_cache == :enabled
    assert resolved.cache_semantics.stable? == true
    assert {:strong, seed} = resolved.cache_semantics.byte_identity
    assert seed[:bucket] == "bucket"
    assert seed[:key] == "cat.jpg"
    assert seed[:revision] == "v1"
  end

  test "s3 without revision isn't stable unless trusted" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ]
             )

    source = %Object{adapter: :s3, scope: "bucket", key: "cat.jpg", revision: nil}

    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert resolved.internal_cache == :disabled
    assert resolved.cache_semantics.byte_identity == :none
  end

  test "empty s3 revision isn't stable under auto mode" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ]
             )

    source = %Object{adapter: :s3, scope: "bucket", key: "cat.jpg", revision: ""}

    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert resolved.internal_cache == :disabled
    assert resolved.cache_semantics.byte_identity == :none
    assert resolved.cache_semantics.stable? == false
  end

  test "per-bucket config overrides defaults and identity includes endpoint bucket key revision" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ],
               buckets: %{
                 "tenant-a" => [
                   region: "eu-west-1",
                   endpoint: "https://s3.eu-west-1.amazonaws.com"
                 ]
               }
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg", revision: "abc"}

    assert {:ok, %Resolved{} = resolved} = S3.resolve(source, opts, [])
    assert resolved.adapter == :s3
    assert resolved.source_kind == :object

    assert resolved.identity == [
             kind: :object,
             adapter: :s3,
             endpoint: "https://s3.eu-west-1.amazonaws.com",
             bucket: "tenant-a",
             key: "images/cat.jpg",
             revision: "abc"
           ]

    refute inspect(resolved.identity) =~ "AKIA"
    refute_received {:fetch_credentials, _, _, _}
  end

  test "timeout configuration is validated and carried into fetch payload" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 receive_timeout: 1_000,
                 connect_timeout: 2_000,
                 pool_timeout: 3_000
               ],
               buckets: %{
                 "tenant-a" => [receive_timeout: 500]
               }
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg"}
    assert {:ok, %Resolved{} = resolved} = S3.resolve(source, opts, [])

    assert Keyword.fetch!(resolved.fetch, :receive_timeout) == 500
    assert Keyword.fetch!(resolved.fetch, :connect_timeout) == 2_000
    assert Keyword.fetch!(resolved.fetch, :pool_timeout) == 3_000

    assert {:error, {:invalid_source_config, _reason}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 receive_timeout: -1
               ]
             )
  end

  test "bucket map fails closed for unlisted buckets" do
    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ],
               buckets: %{"tenant-a" => []}
             )

    assert S3.resolve(%Object{adapter: :s3, scope: "tenant-b", key: "cat.jpg"}, opts, []) ==
             {:error, {:source, :denied_bucket}}
  end

  test "per-bucket credential providers are selected by exact bucket only during fetch" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    # unique bucket names: the credential RefreshCache is application-global and
    # this suite is async, so a shared scope would let another test warm the
    # entry and make these assert/refute_received calls pass tautologically.
    tenant_a = "tenant-a-#{System.unique_integer([:positive])}"
    tenant_b = "tenant-b-#{System.unique_integer([:positive])}"

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 req_options: [plug: plug]
               ],
               buckets: %{
                 tenant_a => [
                   credentials:
                     {:provider, CredentialProvider, role: "tenant-a", report_to: self()}
                 ],
                 tenant_b => [
                   credentials:
                     {:provider, CredentialProvider, role: "tenant-b", report_to: self()}
                 ]
               }
             )

    assert {:ok, resolved} =
             S3.resolve(%Object{adapter: :s3, scope: tenant_b, key: "images/cat.jpg"}, opts, [])

    refute_received {:fetch_credentials, _, _, _}

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{s3: {S3, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:fetch_credentials, ^tenant_b, [role: "tenant-b"], []}
    refute_received {:fetch_credentials, ^tenant_a, _, _}
  end

  test "invalid credential configuration and endpoints fail during option validation" do
    assert {:error, {:invalid_source_config, :missing_credentials}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com"
               ]
             )

    assert {:error, {:invalid_source_config, :missing_credentials}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"}
               ],
               buckets: %{
                 "tenant-a" => [credentials: nil]
               }
             )

    assert {:error, {:invalid_source_config, _reason}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:static, access_key_id: "A"}
               ]
             )

    assert {:error, {:invalid_source_config, _reason}} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:provider, NotLoadedProvider, []}
               ]
             )

    for endpoint <- [
          "s3.amazonaws.com",
          "ftp://s3.amazonaws.com",
          "https://user@s3.amazonaws.com",
          "https://s3.amazonaws.com:abc",
          "https://s3.amazonaws.com:",
          "https://s3.amazonaws.com:+443",
          "https://s3.amazonaws.com:99999",
          "https://[::1]:abc",
          "https://[::1]:+9000",
          "https://s3.amazonaws.com/prefix",
          "https://s3.amazonaws.com?region=us-east-1",
          "https://s3.amazonaws.com#fragment"
        ] do
      assert {:error, {:invalid_source_config, _reason}} =
               S3.validate_options(
                 default: [
                   region: "us-east-1",
                   endpoint: endpoint,
                   credentials: {:static, access_key_id: "A", secret_access_key: "S"}
                 ]
               )
    end
  end

  test "fetch signs only after cache miss and sends versioned object request" do
    plug = fn conn ->
      send(self(), {:s3_request, conn.req_headers, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    # unique bucket name — the credential RefreshCache is application-global and
    # this suite is async, so a shared scope could pre-warm the entry elsewhere.
    tenant = "tenant-a-#{System.unique_integer([:positive])}"

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test/",
                 credentials:
                   {:provider, CredentialProvider, role: "tenant-a", report_to: self()},
                 req_options: [plug: plug]
               ]
             )

    source = %Object{adapter: :s3, scope: tenant, key: "images/cat.jpg", revision: "abc"}

    assert {:ok, resolved} = S3.resolve(source, opts, [])
    assert resolved.identity[:endpoint] == "https://minio.test"
    refute_received {:fetch_credentials, _, _, _}

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{s3: {S3, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:fetch_credentials, ^tenant, [role: "tenant-a"], []}
    assert_receive {:s3_request, headers, path, "versionId=abc"}
    assert path == "/#{tenant}/images/cat.jpg"
    assert {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization =~ "AWS4-HMAC-SHA256"
    assert authorization =~ "/us-east-1/s3/aws4_request"

    assert {"x-amz-security-token", "TOKEN_TEST"} =
             List.keyfind(headers, "x-amz-security-token", 0)
  end

  test "fetch percent-encodes decoded object keys and revisions once" do
    plug = fn conn ->
      send(self(), {:s3_request, conn.req_headers, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 req_options: [plug: plug]
               ]
             )

    source = %Object{
      adapter: :s3,
      scope: "tenant-a",
      key: "images/cat#one%two space?.jpg",
      revision: "a&b=c"
    }

    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{s3: {S3, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"

    assert_receive {:s3_request, headers, request_path, query_string}
    assert request_path == "/tenant-a/images/cat%23one%25two%20space%3F.jpg"
    assert query_string == "versionId=a%26b%3Dc"
    refute request_path =~ "%2523"
    refute query_string =~ "%2526"
    assert {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization =~ "/us-east-1/s3/aws4_request"
  end

  test "req options cannot override S3 request controls or signing service" do
    plug = fn conn ->
      send(
        self(),
        {:s3_request, conn.method, conn.req_headers, conn.request_path, conn.query_string}
      )

      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 req_options: [
                   plug: plug,
                   url: "https://evil.example/other",
                   base_url: "https://evil.example",
                   method: :post,
                   body: "not image",
                   params: [versionId: "evil"],
                   into: :self,
                   retry: true,
                   max_redirects: 10,
                   auth: {:bearer, "evil"},
                   headers: [
                     {"Authorization", "Bearer evil"},
                     {"X-Amz-Security-Token", "evil-token"},
                     {"Host", "evil.example"},
                     {"X-Amz-Content-Sha256", "evil-sha"},
                     {"Range", "bytes=0-1"},
                     {"Accept", "application/json"},
                     {"x-extra", "kept"}
                   ],
                   aws_sigv4: [service: :execute_api, region: "us-east-1"]
                 ]
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg"}
    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{s3: {S3, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"

    assert_receive {:s3_request, "GET", headers, "/tenant-a/images/cat.jpg", ""}
    assert {"authorization", authorization} = List.keyfind(headers, "authorization", 0)
    assert authorization =~ "/us-east-1/s3/aws4_request"

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute authorization =~ "Bearer evil"
  end

  test "stable S3 byte identity strips byte-changing headers even when internal cache is disabled" do
    plug = fn conn ->
      send(self(), {:s3_request, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://minio.test",
                 stable: :trusted,
                 internal_cache: :disabled,
                 credentials: {:static, access_key_id: "A", secret_access_key: "S"},
                 req_options: [
                   plug: plug,
                   headers: [
                     {"Range", "bytes=0-1"},
                     {"Accept", "application/json"},
                     {"Accept-Encoding", "gzip"},
                     {"x-extra", "kept"}
                   ]
                 ]
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg"}
    assert {:ok, resolved} = S3.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{s3: {S3, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:s3_request, headers}

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute Enum.any?(headers, fn {name, _value} ->
             String.downcase(name) in ["range", "accept", "accept-encoding"]
           end)
  end

  test "credential failures are safe source errors" do
    defmodule FailingProvider do
      def fetch_credentials(_scope, _provider_opts, _runtime_opts),
        do: {:error, {:source, :credentials_unavailable}}
    end

    assert {:ok, opts} =
             S3.validate_options(
               default: [
                 region: "us-east-1",
                 endpoint: "https://s3.amazonaws.com",
                 credentials: {:provider, FailingProvider, []}
               ]
             )

    source = %Object{adapter: :s3, scope: "tenant-a", key: "images/cat.jpg"}
    assert {:ok, resolved} = S3.resolve(source, opts, [])
    assert S3.fetch(resolved, opts, []) == {:error, {:source, :credentials_unavailable}}
  end
end
