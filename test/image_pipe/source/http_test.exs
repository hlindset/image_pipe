defmodule ImagePipe.Source.HTTPTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  @public_ip {93, 184, 216, 34}

  defp stub_resolver(extra \\ %{}) do
    base = %{"assets.example.com" => {:ok, [@public_ip]}}
    map = Map.merge(base, extra)
    fn host -> Map.get(map, host, {:error, :nxdomain}) end
  end

  defp fetch_stream(opts_kw, source) do
    {:ok, response} = fetch_response(opts_kw, source)
    response.stream
  end

  defp fetch_response(opts_kw, source) do
    {:ok, opts} = HTTP.validate_options(opts_kw)
    {:ok, resolved} = HTTP.resolve(source, opts, [])

    Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 64)
  end

  defp ok_plug do
    fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end
  end

  test "http source defaults to mutable identity with origin-governed internal caching" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"])
    source = %URL{scheme: :https, host: "example.com", path: ["cat.jpg"]}

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert resolved.internal_cache == :enabled
    assert resolved.cache_semantics.byte_identity == :none
  end

  test "http trusted byte identity doesn't expose raw query" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"], stable: :trusted)

    source = %URL{
      scheme: :https,
      host: "example.com",
      path: ["cat.jpg"],
      query: "X-Amz-Signature=secret"
    }

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])
    assert {:strong, seed} = resolved.cache_semantics.byte_identity
    refute inspect(seed) =~ "X-Amz-Signature=secret"
    assert is_binary(seed[:query_sha256])
  end

  test "resolve normalizes URL identity and enforces allowed hosts" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat.jpg"],
      query: "v=1"
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.adapter == :https
    assert resolved.source_kind == :url

    assert resolved.identity == [
             kind: :url,
             adapter: :https,
             scheme: :https,
             host: "assets.example.com",
             port: 443,
             path: ["images", "cat.jpg"],
             query: "v=1"
           ]

    denied = %URL{source | host: "evil.example"}
    assert HTTP.resolve(denied, opts, []) == {:error, {:source, :denied_host}}
  end

  test "resolve lowercases URL hosts before allowed-host checks and cache identity" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["assets.example.com"])

    source = %URL{
      scheme: :https,
      host: "Assets.Example.Com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.identity[:host] == "assets.example.com"
  end

  test "resolve matches a mixed-case allowed_hosts config entry against a lowercased host" do
    assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["Assets.Example.Com"])

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.identity[:host] == "assets.example.com"
  end

  test "resolve honors HTTP internal cache disabled option" do
    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               internal_cache: :disabled
             )

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, %Resolved{} = resolved} = HTTP.resolve(source, opts, [])
    assert resolved.internal_cache == :disabled
  end

  test "fetch creates a Req-backed lazy stream and preserves safe request options" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 200, "image bytes") end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
  end

  test "req options cannot override adapter request controls" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      send(
        self(),
        {:http_request, conn.method, conn.req_headers, conn.request_path, conn.query_string, body}
      )

      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               internal_cache: :enabled,
               address_resolver: stub_resolver(),
               req_options: [
                 plug: plug,
                 url: "https://evil.example/other.jpg",
                 base_url: "https://evil.example",
                 method: :post,
                 body: "not image",
                 params: [v: "evil"],
                 headers: [
                   {"Host", "evil.example"},
                   {"Range", "bytes=0-1"},
                   {"Accept", "application/json"},
                   {"x-extra", "kept"}
                 ],
                 into: :self,
                 retry: true,
                 max_redirects: 10
               ]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "GET", headers, "/cat.jpg", "", ""}

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute Enum.any?(headers, fn {name, value} ->
             String.downcase(name) in ["host", "range", "accept", "accept-encoding"] and
               value in ["evil.example", "bytes=0-1", "application/json"]
           end)
  end

  test "trusted byte identity strips byte-changing headers even when internal cache is disabled" do
    plug = fn conn ->
      send(self(), {:http_request, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["cat.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               stable: :trusted,
               internal_cache: :disabled,
               address_resolver: stub_resolver(),
               req_options: [
                 plug: plug,
                 headers: [
                   {"Range", "bytes=0-1"},
                   {"Accept", "application/json"},
                   {"Accept-Encoding", "gzip"},
                   {"x-extra", "kept"}
                 ]
               ]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, headers}

    assert {_name, "kept"} =
             Enum.find(headers, fn {name, _value} -> String.downcase(name) == "x-extra" end)

    refute Enum.any?(headers, fn {name, _value} ->
             String.downcase(name) in ["range", "accept", "accept-encoding"]
           end)
  end

  test "configured max redirects allows bounded redirects" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "/other.jpg")
        |> Plug.Conn.send_resp(302, "")

      conn ->
        send(self(), {:http_request, conn.request_path})
        Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               max_redirects: 1,
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "/other.jpg"}
  end

  test "req options cannot override redirect policy" do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_header("location", "https://assets.example.com/other.jpg")
      |> Plug.Conn.send_resp(302, "")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               address_resolver: stub_resolver(),
               req_options: [plug: plug, max_redirects: 10]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:error, {:source, :redirect_not_followed}} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)
  end

  test "fetch percent-encodes decoded path segments when building the request URL" do
    plug = fn conn ->
      send(self(), {:http_request, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["images", "cat#one%two space?.jpg"],
      query: "v=a%26b%3Dc"
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "/images/cat%23one%25two%20space%3F.jpg", "v=a%26b%3Dc"}
  end

  test "fetch brackets IPv6 literals when building the request URL" do
    plug = fn conn ->
      send(self(), {:http_request, conn.host, conn.request_path, conn.query_string})
      Plug.Conn.send_resp(conn, 200, "image bytes")
    end

    source = %URL{
      scheme: :http,
      host: "::1",
      port: 8080,
      path: ["cat.jpg"],
      query: "v=1"
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["::1"],
               address_policy: [allow_loopback: true],
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert resolved.fetch[:url] == "http://[::1]:8080/cat.jpg?v=1"

    assert {:ok, %Response{} = response} =
             Source.fetch(resolved, [sources: %{http: {HTTP, opts}}], max_body_bytes: 20)

    assert Enum.join(response.stream) == "image bytes"
    assert_receive {:http_request, "::1", "/cat.jpg", "v=1"}
  end

  test "non-success status fails during fetch before exposing a body" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 404, "not found") end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["missing.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:error, {:source, {:bad_status, 404}}} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)
  end

  test "an enabled redirect to an off-allowlist host is denied" do
    plug = fn
      %{request_path: "/redirect.jpg"} = conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "https://evil.example/x.jpg")
        |> Plug.Conn.send_resp(302, "")

      _conn ->
        flunk("must not connect to the off-allowlist redirect target")
    end

    source = %URL{
      scheme: :https,
      host: "assets.example.com",
      port: nil,
      path: ["redirect.jpg"],
      query: nil
    }

    assert {:ok, opts} =
             HTTP.validate_options(
               allowed_hosts: ["assets.example.com"],
               max_redirects: 1,
               address_resolver: stub_resolver(),
               req_options: [plug: plug]
             )

    assert {:ok, resolved} = HTTP.resolve(source, opts, [])

    assert {:error, {:source, :denied_host}} =
             Source.fetch(resolved, [sources: %{https: {HTTP, opts}}], max_body_bytes: 20)
  end

  describe "address_policy validation" do
    test "rejects a non-list :allow without raising" do
      assert {:error, {:invalid_source_config, _}} =
               HTTP.validate_options(allowed_hosts: ["x"], address_policy: [allow: "10.0.0.0/8"])
    end

    test "rejects non-binary :allow entries without raising" do
      assert {:error, {:invalid_source_config, _}} =
               HTTP.validate_options(allowed_hosts: ["x"], address_policy: [allow: [123]])
    end

    test "rejects an invalid CIDR string" do
      assert {:error, {:invalid_source_config, _}} =
               HTTP.validate_options(
                 allowed_hosts: ["x"],
                 address_policy: [allow: ["10.0.0.0/99"]]
               )
    end

    test "rejects an unknown address_policy key" do
      assert {:error, {:invalid_source_config, _}} =
               HTTP.validate_options(allowed_hosts: ["x"], address_policy: [bogus: true])
    end

    test "accepts a valid keyword policy and a 2-arity function" do
      assert {:ok, _} =
               HTTP.validate_options(
                 allowed_hosts: ["x"],
                 address_policy: [allow_private: true, allow: ["10.0.5.0/24"]]
               )

      assert {:ok, _} =
               HTTP.validate_options(
                 allowed_hosts: ["x"],
                 address_policy: fn _ip, cat -> cat == :public end
               )
    end
  end

  describe "SSRF guard" do
    test "origin host resolving to a private address is blocked (DNS branch)" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      stream =
        fetch_response(
          [
            allowed_hosts: ["assets.example.com"],
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      assert stream == {:error, {:source, :denied_address}}
    end

    test "origin IP-literal private host is blocked (literal branch, no resolver)" do
      source = %URL{scheme: :https, host: "10.0.0.5", path: ["x.jpg"]}

      stream =
        fetch_response(
          [allowed_hosts: ["10.0.0.5"], req_options: [plug: ok_plug()]],
          source
        )

      assert stream == {:error, {:source, :denied_address}}
    end

    test "169.254.169.254 cloud metadata literal is blocked" do
      source = %URL{scheme: :https, host: "169.254.169.254", path: ["latest", "meta-data"]}

      stream =
        fetch_response(
          [allowed_hosts: ["169.254.169.254"], req_options: [plug: ok_plug()]],
          source
        )

      assert stream == {:error, {:source, :denied_address}}
    end

    test "trusted origin redirecting to a loopback target is blocked on the hop" do
      plug = fn
        %{request_path: "/redirect.jpg"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "http://127.0.0.1/x")
          |> Plug.Conn.send_resp(302, "")

        _conn ->
          flunk("must not connect to loopback redirect target")
      end

      source = %URL{scheme: :https, host: "assets.example.com", path: ["redirect.jpg"]}

      stream =
        fetch_response(
          [
            allowed_hosts: ["assets.example.com", "127.0.0.1"],
            max_redirects: 1,
            address_resolver: stub_resolver(),
            req_options: [plug: plug]
          ],
          source
        )

      assert stream == {:error, {:source, :denied_address}}
    end

    test "non-http(s) redirect scheme is rejected" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_header("location", "file:///etc/passwd")
        |> Plug.Conn.send_resp(302, "")
      end

      source = %URL{scheme: :https, host: "assets.example.com", path: ["redirect.jpg"]}

      stream =
        fetch_response(
          [
            allowed_hosts: ["assets.example.com"],
            max_redirects: 1,
            address_resolver: stub_resolver(),
            req_options: [plug: plug]
          ],
          source
        )

      assert stream == {:error, {:source, :denied_scheme}}
    end

    test "allow_private opt-in lets a private origin through" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            address_policy: [allow_private: true],
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      assert Enum.join(stream) == "image bytes"
    end

    test "precise CIDR allow lets only the named range through" do
      source = %URL{scheme: :https, host: "in.example", path: ["x.jpg"]}

      base = [
        allowed_hosts: ["in.example"],
        address_policy: [allow: ["10.0.5.0/24"]],
        req_options: [plug: ok_plug()]
      ]

      ok_stream =
        fetch_stream(
          Keyword.put(
            base,
            :address_resolver,
            stub_resolver(%{"in.example" => {:ok, [{10, 0, 5, 9}]}})
          ),
          source
        )

      assert Enum.join(ok_stream) == "image bytes"

      blocked_stream =
        fetch_response(
          Keyword.put(
            base,
            :address_resolver,
            stub_resolver(%{"in.example" => {:ok, [{10, 0, 6, 9}]}})
          ),
          source
        )

      assert blocked_stream == {:error, {:source, :denied_address}}
    end

    test "an uppercase redirect host still matches the downcased allowlist and is fetched" do
      plug = fn
        %{request_path: "/redirect.jpg"} = conn ->
          conn
          |> Plug.Conn.put_resp_header("location", "https://ASSETS.EXAMPLE.COM/other.jpg")
          |> Plug.Conn.send_resp(302, "")

        conn ->
          Plug.Conn.send_resp(conn, 200, "image bytes")
      end

      source = %URL{scheme: :https, host: "assets.example.com", path: ["redirect.jpg"]}

      stream =
        fetch_stream(
          [
            allowed_hosts: ["assets.example.com"],
            max_redirects: 1,
            address_resolver: stub_resolver(),
            req_options: [plug: plug]
          ],
          source
        )

      assert Enum.join(stream) == "image bytes"
    end

    test "function-form policy replaces the built-in decision" do
      source = %URL{scheme: :https, host: "assets.example.com", path: ["x.jpg"]}

      blocked =
        fetch_response(
          [
            allowed_hosts: ["assets.example.com"],
            address_policy: fn _ip, category -> category == :public end,
            address_resolver: stub_resolver(%{"assets.example.com" => {:ok, [{10, 0, 0, 5}]}}),
            req_options: [plug: ok_plug()]
          ],
          source
        )

      assert blocked == {:error, {:source, :denied_address}}
    end
  end
end
