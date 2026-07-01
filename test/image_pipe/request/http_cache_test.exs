defmodule ImagePipe.Request.HTTPCacheTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Conn
  import Plug.Test
  import StreamData

  alias ImagePipe.Cache.Key
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Request.HTTPCache
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  defp plan(output \\ %Output{mode: {:explicit, :webp}}) do
    %Plan{
      source: %SourcePath{segments: ["cat.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: output
    }
  end

  defp resolved(overrides \\ []) do
    struct!(
      %Resolved{
        adapter: :path,
        source_kind: :path,
        identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
        internal_cache: :enabled,
        http_cache: :inherit,
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :path, root: "test", path: ["cat.jpg"]]},
          stable?: true
        },
        fetch: [path: "/tmp/cat.jpg"]
      },
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        http_cache: [mode: :enabled],
        telemetry_prefix: [:image_pipe],
        max_result_width: 8_192
      ],
      overrides
    )
  end

  test "enabled mode with strong byte identity emits cache-control and strong etag" do
    prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert %ImagePipe.Response.CacheHeaders{
             representation_headers: [],
             headers: headers,
             etag: etag
           } = prepared

    assert {"cache-control", "public, max-age=31536000, immutable"} in headers
    assert {"etag", etag} in headers
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "disabled mode emits no generated cache headers" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(),
        opts(http_cache: [mode: :disabled])
      )

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "non-GET requests emit no generated cache headers" do
    prepared = HTTPCache.prepare(conn(:post, "/image"), plan(), resolved(), opts())

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "missing byte identity emits no-store fallback without generated etag" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}),
        opts()
      )

    assert prepared.headers == [{"cache-control", "no-store"}]
    assert prepared.etag == nil
  end

  test "host cache-control suppresses generated cache-control and no-store fallback" do
    conn = put_resp_header(conn(:get, "/image"), "cache-control", "public, max-age=60")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(),
        resolved(cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}),
        opts()
      )

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "host etag suppresses generated etag" do
    conn = put_resp_header(conn(:get, "/image"), "etag", ~s("host"))

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    refute Enum.any?(prepared.headers, fn {name, _value} -> name == "etag" end)
    assert {"cache-control", "public, max-age=31536000, immutable"} in prepared.headers
    assert prepared.etag == nil
  end

  test "automatic output emits representation Vary Accept" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image") |> put_req_header("accept", "image/avif,image/webp"),
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept"}]
  end

  test "existing vary merges accept without duplicates" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "Accept-Encoding, Accept")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept-Encoding, Accept"}]
  end

  test "existing vary star suppresses generated public cache headers but keeps representation headers" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "*")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "*"}]
    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "existing vary star suppresses generated public cache headers for explicit output" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "*")

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    assert prepared.representation_headers == []
    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "set-cookie suppresses generated public cache headers" do
    conn = put_resp_header(conn(:get, "/image"), "set-cookie", "a=b")

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "response cookies suppress generated public cache headers" do
    conn = put_resp_cookie(conn(:get, "/image"), "session", "abc")

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "cache-control no-store suppresses generated etag" do
    conn = put_resp_header(conn(:get, "/image"), "cache-control", "no-store")

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "explicit output doesn't emit Vary Accept" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(%Output{mode: {:explicit, :jpeg}}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == []
  end

  test "client hints don't enter generated vary" do
    conn =
      conn(:get, "/image")
      |> put_req_header("width", "600")
      |> put_req_header("dpr", "2")
      |> put_req_header("sec-ch-width", "600")

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    refute Enum.any?(prepared.representation_headers, fn {_name, value} ->
             String.contains?(String.downcase(value), "width")
           end)
  end

  test "plan expires does not change generated cache-control" do
    base = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    expiring =
      HTTPCache.prepare(
        conn(:get, "/image"),
        %{plan() | expires: 1_899_345_600},
        resolved(),
        opts()
      )

    assert header(base.headers, "cache-control") == header(expiring.headers, "cache-control")
  end

  test "auto_rotate changes the generated etag (unlike cachebuster)" do
    off =
      HTTPCache.prepare(conn(:get, "/image"), %{plan() | auto_rotate: false}, resolved(), opts())

    on =
      HTTPCache.prepare(conn(:get, "/image"), %{plan() | auto_rotate: true}, resolved(), opts())

    refute off.etag == on.etag
  end

  test "cachebuster changes internal key data but not generated etag" do
    base_plan = plan()
    busted_plan = %{plan() | cachebuster: "v2"}
    plug_conn = conn(:get, "/image")

    assert {:ok, base_key} =
             Key.build(plug_conn, base_plan, resolved().identity, opts())

    assert {:ok, busted_key} =
             Key.build(plug_conn, busted_plan, resolved().identity, opts())

    assert base_key.data[:cache] != busted_key.data[:cache]

    base = HTTPCache.prepare(conn(:get, "/image"), base_plan, resolved(), opts())
    busted = HTTPCache.prepare(conn(:get, "/image"), busted_plan, resolved(), opts())

    assert base.etag == busted.etag
  end

  test "source revision changes generated etag" do
    left =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{
            byte_identity:
              {:strong,
               [kind: :object, adapter: :s3, bucket: "b", key: "cat.jpg", revision: "v1"]},
            stable?: true
          }
        ),
        opts()
      )

    right =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{
            byte_identity:
              {:strong,
               [kind: :object, adapter: :s3, bucket: "b", key: "cat.jpg", revision: "v2"]},
            stable?: true
          }
        ),
        opts()
      )

    assert left.etag != right.etag
  end

  test "visible etag prefix comes from etag schema" do
    prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert String.starts_with?(prepared.etag, ~s("ip#{HTTPCache.etag_schema()}-))
  end

  test "etag material uses the internal cache representation version" do
    assert {:strong, seed} = resolved().cache_semantics.byte_identity

    assert {:ok, material} = HTTPCache.etag_material(conn(:get, "/image"), plan(), seed, opts())

    assert material[:plan][:representation] == [
             version: Key.representation_version()
           ]
  end

  test "cookie request header does not enter generated vary or etag" do
    without_cookie = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    with_cookie =
      :get
      |> conn("/image")
      |> put_req_header("cookie", "session=private")
      |> HTTPCache.prepare(plan(), resolved(), opts())

    assert with_cookie.etag == without_cookie.etag

    refute "cookie" in vary_tokens(with_cookie.representation_headers)
  end

  describe "evaluate_conditional/3" do
    test "weak request tag matches generated strong etag for GET" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s(W/"ip1-abc"))

      assert {:not_modified, ^prepared} = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    property "whitespace around if-none-match tags doesn't change matching" do
      check all left <- member_of(["", " ", "  ", "\t"]),
                right <- member_of(["", " ", "  ", "\t"]) do
        prepared = %ImagePipe.Response.CacheHeaders{
          representation_headers: [],
          headers: [{"etag", ~s("ip1-token")}],
          etag: ~s("ip1-token")
        }

        conn =
          :get
          |> conn("/image")
          |> put_req_header("if-none-match", left <> ~s(W/"ip1-token") <> right)

        assert {:not_modified, ^prepared} = HTTPCache.evaluate_conditional(conn, prepared, [])
      end
    end

    test "comma-separated weak and strong tags can match generated etag" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-token")}],
        etag: ~s("ip1-token")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("other", W/"ip1-token"))

      assert {:not_modified, ^prepared} = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "wildcard form proceeds pre-fetch (honored only on an internal cache hit)" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-abc", *))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "host etag isn't interpreted when prepared etag is nil" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [],
        etag: nil
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("host"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "non-matching if-none-match proceeds" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-other"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "malformed if-none-match proceeds" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :get
        |> conn("/image")
        |> put_req_header("if-none-match", "not-a-quoted-tag")

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end

    test "non-cacheable methods do not use conditional response handling" do
      prepared = %ImagePipe.Response.CacheHeaders{
        representation_headers: [],
        headers: [{"etag", ~s("ip1-abc")}],
        etag: ~s("ip1-abc")
      }

      conn =
        :post
        |> conn("/image")
        |> put_req_header("if-none-match", ~s("ip1-abc"))

      assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
    end
  end

  describe "if_none_match_wildcard?/1" do
    test "true for a bare wildcard" do
      conn = conn(:get, "/image") |> put_req_header("if-none-match", "*")
      assert HTTPCache.if_none_match_wildcard?(conn)
    end

    test "true when a wildcard is mixed with explicit tags (collapse)" do
      conn = conn(:get, "/image") |> put_req_header("if-none-match", ~s("ip1-abc", *))
      assert HTTPCache.if_none_match_wildcard?(conn)
    end

    test "false for explicit tags only" do
      conn = conn(:get, "/image") |> put_req_header("if-none-match", ~s("ip1-abc"))
      refute HTTPCache.if_none_match_wildcard?(conn)
    end

    test "false when the header is absent" do
      refute HTTPCache.if_none_match_wildcard?(conn(:get, "/image"))
    end
  end

  test "equivalent Accept capability material produces the same generated etag" do
    left =
      :get
      |> conn("/image")
      |> put_req_header("accept", "image/avif,image/webp")
      |> HTTPCache.prepare(plan(%Output{mode: :automatic}), resolved(), opts())

    right =
      :get
      |> conn("/image")
      |> put_req_header("accept", "image/avif;q=1.0,image/webp;q=0.8")
      |> HTTPCache.prepare(plan(%Output{mode: :automatic}), resolved(), opts())

    assert left.etag == right.etag
  end

  test "missing empty and wildcard-only Accept material produces the same generated etag" do
    assert {:strong, seed} = resolved().cache_semantics.byte_identity
    automatic_plan = plan(%Output{mode: :automatic})

    conns = [
      conn(:get, "/image"),
      conn(:get, "/image") |> put_req_header("accept", ""),
      conn(:get, "/image") |> put_req_header("accept", "*/*"),
      conn(:get, "/image") |> put_req_header("accept", "*/*;q=1"),
      conn(:get, "/image") |> put_req_header("accept", "application/json,*/*;q=1")
    ]

    prepared = Enum.map(conns, &HTTPCache.prepare(&1, automatic_plan, resolved(), opts()))

    assert prepared |> Enum.map(& &1.etag) |> Enum.uniq() |> length() == 1

    for conn <- conns do
      assert {:ok, material} = HTTPCache.etag_material(conn, automatic_plan, seed, opts())
      assert material[:accept] == []
      refute inspect(material) =~ "*/*"
      refute inspect(material) =~ "application/json"
    end
  end

  test "different source byte identities produce different generated etags" do
    left = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    right =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{
            byte_identity: {:strong, [kind: :path, root: "test", path: ["other.jpg"]]},
            stable?: true
          }
        ),
        opts()
      )

    assert left.etag != right.etag
  end

  test "etag serialization is deterministic for the same prepared inputs" do
    first = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())
    second = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert first.etag == second.etag
  end

  test "prepare telemetry is low-cardinality" do
    attach_telemetry([[:image_pipe, :http_cache, :prepare]])

    _prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert_receive {:telemetry_event, [:image_pipe, :http_cache, :prepare], %{}, metadata}
    assert metadata == %{effective_mode: :enabled, byte_identity: :strong, etag: true}
  end

  test "no-store fallback telemetry is required and low-cardinality" do
    attach_telemetry([[:image_pipe, :http_cache, :fallback, :no_store]])

    _prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}),
        opts()
      )

    assert_receive {:telemetry_event, [:image_pipe, :http_cache, :fallback, :no_store], %{},
                    metadata}

    assert metadata == %{adapter: :path, source_kind: :path, reason: :missing_byte_identity}
  end

  test "conditional match telemetry omits etag and path" do
    attach_telemetry([[:image_pipe, :http_cache, :conditional, :match]])

    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-token")}],
      etag: ~s("ip1-token")
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", ~s("ip1-token"))

    assert {:not_modified, ^prepared} = HTTPCache.evaluate_conditional(conn, prepared, opts())

    assert_receive {:telemetry_event, [:image_pipe, :http_cache, :conditional, :match], %{},
                    metadata}

    assert metadata == %{method: :get}
  end

  defp header(headers, name) do
    headers
    |> Enum.find(fn {header_name, _value} -> header_name == name end)
    |> elem(1)
  end

  defp vary_tokens(headers) do
    headers
    |> Enum.filter(fn {name, _value} -> name == "vary" end)
    |> Enum.flat_map(fn {_name, value} -> String.split(value, ",") end)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
  end

  def handle_telemetry_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry_event, event, measurements, metadata})
  end

  defp attach_telemetry(events) do
    test_pid = self()
    handler_id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.handle_telemetry_event/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
