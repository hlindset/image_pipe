defmodule ImagePipe.Source.OriginFetchTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.URL
  alias ImagePipe.Source
  alias ImagePipe.Source.HTTP
  alias ImagePipe.Source.Origin
  alias ImagePipe.Test.RawSourceOrigin

  defp config(plug) do
    ImagePipe.Plug.init(
      sources: [
        url:
          {HTTP,
           allowed_hosts: ["origin.test"],
           address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
           req_options: [plug: plug]}
      ]
    )
  end

  defp resolve(config) do
    {:ok, source} =
      Source.resolve(
        %URL{scheme: :https, host: "origin.test", path: ["cat.jpg"]},
        config,
        Source.runtime_opts(config)
      )

    source
  end

  test "origin metadata is available before consuming the body" do
    opts =
      config(fn conn ->
        conn
        |> Plug.Conn.put_resp_header("cache-control", "public, max-age=60")
        |> Plug.Conn.put_resp_header("etag", ~s(W/"source-v1"))
        |> Plug.Conn.send_resp(200, "original bytes")
      end)

    Source.with_fetched(resolve(opts), opts, fn response ->
      assert response.origin.status == 200
      assert Origin.validator_headers(response.origin) == [{"if-none-match", ~s(W/"source-v1")}]

      assert Source.CacheState.status(
               Origin.cache_state(response.origin, [], false),
               response.origin.received_at
             ) == :fresh

      assert Enum.join(response.stream) == "original bytes"
    end)
  end

  test "revalidation sends origin validators and merges 304 metadata" do
    plug = fn conn ->
      case Plug.Conn.get_req_header(conn, "if-none-match") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s("v1"))
          |> Plug.Conn.put_resp_header("cache-control", "max-age=0")
          |> Plug.Conn.send_resp(200, "original bytes")

        [~s("v1")] ->
          conn
          |> Plug.Conn.put_resp_header("cache-control", "max-age=300")
          |> Plug.Conn.send_resp(304, "")
      end
    end

    opts = config(plug)
    source = resolve(opts)

    previous =
      Source.with_fetched(source, opts, fn response ->
        assert Enum.join(response.stream) == "original bytes"
        response.origin
      end)

    assert {:not_modified, refreshed} =
             Source.with_revalidated(source, previous, opts, fn _ ->
               flunk("304 must not decode or replace bytes")
             end)

    assert refreshed.headers["etag"] == [~s("v1")]
    assert refreshed.headers["cache-control"] == ["max-age=300"]

    assert Source.CacheState.status(
             Origin.cache_state(refreshed, [], false),
             refreshed.received_at
           ) == :fresh
  end

  test "changed 200 during revalidation supplies new metadata and bytes" do
    opts =
      config(fn conn ->
        version =
          case Plug.Conn.get_req_header(conn, "if-none-match") do
            [] -> "v1"
            _ -> "v2"
          end

        conn
        |> Plug.Conn.put_resp_header("etag", ~s("#{version}"))
        |> Plug.Conn.send_resp(200, version)
      end)

    source = resolve(opts)

    previous =
      Source.with_fetched(source, opts, fn response ->
        Enum.join(response.stream)
        response.origin
      end)

    result =
      Source.with_revalidated(source, previous, opts, fn response ->
        assert response.origin.headers["etag"] == [~s("v2")]
        Enum.join(response.stream)
      end)

    assert result == "v2"
  end

  test "an unsolicited 304 is an error rather than a redirect or empty source" do
    opts = config(&Plug.Conn.send_resp(&1, 304, ""))

    assert {:error, {:source, :unexpected_not_modified}} =
             Source.with_fetched(resolve(opts), opts, fn _ -> flunk("no body") end)
  end

  test "headers-only consumers release an untouched remote body" do
    origin =
      start_supervised!(
        {RawSourceOrigin,
         test_pid: self(),
         response: "HTTP/1.1 200 OK\r\ncontent-length: 100\r\n\r\n",
         finish: :stall}
      )

    assert_receive {:origin_ready, ^origin, url}
    monitor = Process.monitor(origin)
    uri = URI.parse(url)

    opts =
      ImagePipe.Plug.init(
        sources: [
          url: {HTTP, allowed_hosts: ["127.0.0.1"], address_policy: [allow_loopback: true]}
        ]
      )

    {:ok, source} =
      Source.resolve(
        %URL{scheme: :http, host: uri.host, port: uri.port, path: ["cat.jpg"]},
        opts,
        Source.runtime_opts(opts)
      )

    assert :headers_only =
             Source.with_fetched(source, opts, fn response ->
               assert response.origin.status == 200
               :headers_only
             end)

    assert_receive {:DOWN, ^monitor, :process, ^origin, :normal}
  end

  test "authenticated sources need origin permission or an explicit storage override" do
    opts =
      config(fn conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer secret"]

        conn
        |> Plug.Conn.put_resp_header("cache-control", "max-age=60")
        |> Plug.Conn.put_resp_header("vary", "Authorization")
        |> Plug.Conn.send_resp(200, "bytes")
      end)

    {module, http} = opts[:sources][:https]
    http = Keyword.update!(http, :req_options, &Keyword.put(&1, :auth, {:bearer, "secret"}))
    opts = Keyword.put(opts, :sources, %{https: {module, http}})

    Source.with_fetched(resolve(opts), opts, fn response ->
      origin = response.origin
      refute inspect(origin) =~ "secret"
      assert origin.authenticated?
      refute Origin.cache_state(origin, [], false).storable?
      assert Origin.cache_state(origin, [storage: :allow], false).storable?
      assert Origin.matches?(origin, %{"authorization" => ["Bearer secret"]})
      refute Origin.matches?(origin, %{"authorization" => ["Bearer different"]})
    end)
  end

  test "Last-Modified is used when no ETag exists, with deterministic 304 age refresh" do
    date = "Sun, 06 Nov 1994 08:49:37 GMT"

    opts =
      config(fn conn ->
        case Plug.Conn.get_req_header(conn, "if-modified-since") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("last-modified", date)
            |> Plug.Conn.put_resp_header("age", "120")
            |> Plug.Conn.put_resp_header("cache-control", "max-age=60")
            |> Plug.Conn.send_resp(200, "bytes")

          [^date] ->
            conn |> Plug.Conn.delete_resp_header("cache-control") |> Plug.Conn.send_resp(304, "")
        end
      end)
      |> Keyword.put(:clock, fn -> 1_000 end)

    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)

    assert Source.CacheState.status(Origin.cache_state(previous, [], false), 1_000) ==
             :requires_validation

    assert {:not_modified, current} =
             Source.with_revalidated(source, previous, opts, fn _ -> flunk("304") end)

    assert Origin.cache_state(current, [], false).fresh_until == 1_060
  end

  test "a 304 with a different entity tag is rejected" do
    opts =
      config(fn conn ->
        case Plug.Conn.get_req_header(conn, "if-none-match") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("v1"))
            |> Plug.Conn.send_resp(200, "bytes")

          _ ->
            conn |> Plug.Conn.put_resp_header("etag", ~s("v2")) |> Plug.Conn.send_resp(304, "")
        end
      end)

    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)

    assert {:error, {:source, :invalid_not_modified}} =
             Source.with_revalidated(source, previous, opts, fn _ -> flunk("invalid 304") end)
  end

  test "without validators revalidation fetches a complete response" do
    opts =
      config(fn conn ->
        assert Plug.Conn.get_req_header(conn, "if-none-match") == []
        assert Plug.Conn.get_req_header(conn, "if-modified-since") == []
        Plug.Conn.send_resp(conn, 200, "bytes")
      end)

    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)
    assert "bytes" == Source.with_revalidated(source, previous, opts, &Enum.join(&1.stream))
  end

  test "a failed revalidation is not an unchanged source" do
    opts =
      config(fn conn ->
        case Plug.Conn.get_req_header(conn, "if-none-match") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("etag", ~s("v1"))
            |> Plug.Conn.send_resp(200, "bytes")

          _ ->
            Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)

    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)

    assert {:error, {:source, {:bad_status, 503}}} =
             Source.with_revalidated(source, previous, opts, fn _ ->
               flunk("failed validation")
             end)
  end

  test "S3 revalidation signs requests while keeping origin validators separate" do
    plug = fn conn ->
      assert [authorization] = Plug.Conn.get_req_header(conn, "authorization")
      assert String.starts_with?(authorization, "AWS4-HMAC-SHA256")

      case Plug.Conn.get_req_header(conn, "if-none-match") do
        [] ->
          conn
          |> Plug.Conn.put_resp_header("etag", ~s(W/"object-v1"))
          |> Plug.Conn.send_resp(200, "bytes")

        [~s(W/"object-v1")] ->
          Plug.Conn.send_resp(conn, 304, "")
      end
    end

    opts =
      ImagePipe.Plug.init(
        sources: [
          s3:
            {Source.S3,
             default: [
               region: "us-east-1",
               endpoint: "https://s3.test",
               credentials: {:static, access_key_id: "A", secret_access_key: "S"},
               req_options: [plug: plug]
             ]}
        ]
      )

    intent = %ImagePipe.Plan.Source.Object{
      adapter: :s3,
      scope: "bucket",
      key: "cat.jpg",
      revision: nil
    }

    {:ok, source} = Source.resolve(intent, opts, Source.runtime_opts(opts))
    previous = Source.with_fetched(source, opts, & &1.origin)
    assert source.cache_semantics.byte_identity == :none

    assert {:not_modified, refreshed} =
             Source.with_revalidated(source, previous, opts, fn _ ->
               flunk("unchanged S3 object")
             end)

    assert refreshed.headers["etag"] == [~s(W/"object-v1")]
  end

  test "revalidation sends validators only to their resource across redirects" do
    plug = fn conn ->
      case conn.request_path do
        "/cat.jpg" ->
          assert Plug.Conn.get_req_header(conn, "if-none-match") == []

          conn
          |> Plug.Conn.put_resp_header("location", "/final.jpg")
          |> Plug.Conn.send_resp(302, "")

        "/final.jpg" ->
          case Plug.Conn.get_req_header(conn, "if-none-match") do
            [] ->
              conn
              |> Plug.Conn.put_resp_header("etag", ~s("final"))
              |> Plug.Conn.send_resp(200, "bytes")

            [~s("final")] ->
              Plug.Conn.send_resp(conn, 304, "")
          end
      end
    end

    opts = config(plug)
    {module, http} = opts[:sources][:https]
    opts = Keyword.put(opts, :sources, %{https: {module, Keyword.put(http, :max_redirects, 1)}})
    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)

    assert {:not_modified, _} =
             Source.with_revalidated(source, previous, opts, fn _ ->
               flunk("unchanged redirected source")
             end)
  end

  test "changed Vary inputs fetch new bytes without the previous validator" do
    plug = fn conn ->
      [tenant] = Plug.Conn.get_req_header(conn, "x-tenant")
      assert Plug.Conn.get_req_header(conn, "if-none-match") == []

      conn
      |> Plug.Conn.put_resp_header("vary", "X-Tenant")
      |> Plug.Conn.put_resp_header("etag", ~s("same-tag"))
      |> Plug.Conn.send_resp(200, tenant)
    end

    opts = with_headers(config(plug), [{"x-tenant", "first"}])
    previous = Source.with_fetched(resolve(opts), opts, & &1.origin)
    opts = with_headers(opts, [{"x-tenant", "second"}])

    assert "second" ==
             Source.with_revalidated(resolve(opts), previous, opts, &Enum.join(&1.stream))
  end

  test "304 retains Vary evidence when the response omits Vary" do
    opts =
      config(fn conn ->
        case Plug.Conn.get_req_header(conn, "if-none-match") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("vary", "X-Tenant")
            |> Plug.Conn.put_resp_header("etag", ~s("v1"))
            |> Plug.Conn.send_resp(200, "bytes")

          _ ->
            Plug.Conn.send_resp(conn, 304, "")
        end
      end)
      |> with_headers([{"x-tenant", "first"}])

    source = resolve(opts)
    previous = Source.with_fetched(source, opts, & &1.origin)

    assert {:not_modified, refreshed} =
             Source.with_revalidated(source, previous, opts, fn _ -> flunk("304") end)

    assert Origin.matches?(refreshed, %{"x-tenant" => ["first"]})
    refute Origin.matches?(refreshed, %{"x-tenant" => ["second"]})
  end

  test "304 rejects repeated or malformed entity tags" do
    for tags <- [[~s("v1"), ~s("v2")], ["unquoted"]] do
      opts =
        config(fn conn ->
          case Plug.Conn.get_req_header(conn, "if-none-match") do
            [] ->
              conn
              |> Plug.Conn.put_resp_header("etag", ~s("v1"))
              |> Plug.Conn.send_resp(200, "bytes")

            _ ->
              headers = Enum.map(tags, &{"etag", &1}) ++ conn.resp_headers
              Plug.Conn.send_resp(%{conn | resp_headers: headers}, 304, "")
          end
        end)

      source = resolve(opts)
      previous = Source.with_fetched(source, opts, & &1.origin)

      assert {:error, {:source, :invalid_not_modified}} =
               Source.with_revalidated(source, previous, opts, fn _ -> flunk("invalid 304") end)
    end
  end

  defp with_headers(opts, headers) do
    {module, http} = opts[:sources][:https]
    http = Keyword.update!(http, :req_options, &Keyword.put(&1, :headers, headers))
    Keyword.put(opts, :sources, %{https: {module, http}})
  end

  test "Vary star forbids storage" do
    opts =
      config(fn conn ->
        conn |> Plug.Conn.put_resp_header("vary", "*") |> Plug.Conn.send_resp(200, "bytes")
      end)

    Source.with_fetched(resolve(opts), opts, fn response ->
      refute Origin.cache_state(response.origin, [storage: :allow], true).storable?
      refute Origin.matches?(response.origin, %{})
    end)
  end
end
