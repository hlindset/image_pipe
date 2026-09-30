defmodule ImagePipe.Response.CachePolicyTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias ImagePipe.Cache.Key
  alias ImagePipe.Representation
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Response.CachePolicy

  @generated "public, max-age=31536000, immutable"

  # A hand-built %Representation{} is legitimate here: it is the value the
  # runner hands this module, and this module's whole contract is a pure
  # function of it. Representation's OWN construction is tested by
  # representation_test.exs.
  defp representation(overrides \\ []) do
    %Representation{
      cache_key: %Key{hash: "deadbeef", data: []},
      etag: Keyword.get(overrides, :etag, ~s("ipr1-abc")),
      vary: Keyword.get(overrides, :vary, []),
      no_store?: Keyword.get(overrides, :no_store?, false)
    }
  end

  defp facts(overrides \\ []) do
    Enum.into(overrides, %{
      http_cache: :inherit,
      byte_identity: {:strong, "seed"},
      stable?: true,
      adapter: ImagePipe.Source.HTTP,
      source_kind: :url
    })
  end

  defp config(overrides \\ []) do
    Keyword.merge(
      [http_cache: [mode: :enabled], telemetry_prefix: [:cache_policy_test]],
      overrides
    )
  end

  test "generates Cache-Control and the representation's ETag when enabled" do
    assert %CacheHeaders{headers: headers, etag: ~s("ipr1-abc")} =
             CachePolicy.generate(conn(:get, "/x"), representation(), facts(), config())

    assert {"cache-control", @generated} in headers
    assert {"etag", ~s("ipr1-abc")} in headers
  end

  test "mode :disabled generates nothing and withholds the ETag" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(),
               facts(),
               config(http_cache: [mode: :disabled])
             )
  end

  test "a per-source :disabled overrides an enabled mount" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(),
               facts(http_cache: :disabled),
               config()
             )
  end

  test "a host Set-Cookie suppresses generation" do
    conn = put_resp_cookie(conn(:get, "/x"), "session", "1")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host Vary: * suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "*")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a representation Vary: * suppresses generation" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(vary: ["*"]),
               facts(),
               config()
             )
  end

  test "a host no-store suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "no-store")

    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host Cache-Control yields the ETag only" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "max-age=60")

    assert %CacheHeaders{headers: [{"etag", ~s("ipr1-abc")}], etag: ~s("ipr1-abc")} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a host ETag is respected: none generated" do
    conn = put_resp_header(conn(:get, "/x"), "etag", ~s("host"))

    assert %CacheHeaders{headers: [{"cache-control", @generated}], etag: nil} =
             CachePolicy.generate(conn, representation(), facts(), config())
  end

  test "a no-store representation gets Cache-Control: no-store and no ETag" do
    assert %CacheHeaders{headers: [{"cache-control", "no-store"}], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(etag: nil, no_store?: true),
               facts(byte_identity: :none, stable?: false),
               config()
             )
  end

  test "a non-GET/HEAD method generates nothing" do
    assert %CacheHeaders{headers: [], etag: nil} =
             CachePolicy.generate(conn(:post, "/x"), representation(), facts(), config())
  end

  test "representation Vary merges with a host Vary, deduplicated" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "Origin")

    assert %CacheHeaders{representation_headers: [{"vary", "Origin, Accept"}]} =
             CachePolicy.generate(conn, representation(vary: ["Accept"]), facts(), config())
  end

  test "prepare telemetry fires with effective_mode, byte_identity, and etag" do
    attach_telemetry([[:cache_policy_test, :http_cache, :prepare]])

    CachePolicy.generate(conn(:get, "/x"), representation(), facts(), config())

    assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :prepare], %{}, metadata}
    assert metadata == %{effective_mode: :enabled, byte_identity: :strong, etag: true}
  end

  test "no-store fallback telemetry fires with adapter, source_kind, and reason" do
    attach_telemetry([[:cache_policy_test, :http_cache, :fallback, :no_store]])

    CachePolicy.generate(
      conn(:get, "/x"),
      representation(etag: nil, no_store?: true),
      facts(byte_identity: :none, stable?: false),
      config()
    )

    assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :fallback, :no_store],
                    %{}, metadata}

    assert metadata == %{
             adapter: ImagePipe.Source.HTTP,
             source_kind: :url,
             reason: :missing_byte_identity
           }
  end

  describe "conditional_matched/2" do
    test "emits [:http_cache, :conditional, :match] with method: :get" do
      attach_telemetry([[:cache_policy_test, :http_cache, :conditional, :match]])

      assert :ok = CachePolicy.conditional_matched(conn(:get, "/x"), config())

      assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :conditional, :match],
                      %{}, metadata}

      assert metadata == %{method: :get}
    end

    test "emits [:http_cache, :conditional, :match] with method: :head" do
      attach_telemetry([[:cache_policy_test, :http_cache, :conditional, :match]])

      assert :ok = CachePolicy.conditional_matched(conn(:head, "/x"), config())

      assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :conditional, :match],
                      %{}, metadata}

      assert metadata == %{method: :head}
    end
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
