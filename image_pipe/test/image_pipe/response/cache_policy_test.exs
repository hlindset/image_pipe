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
      vary: Keyword.get(overrides, :vary, [])
    }
  end

  defp facts(overrides \\ []) do
    Enum.into(overrides, %{
      byte_identity: {:strong, "seed"},
      stable?: true,
      source_mount: :web,
      source_kind: :url
    })
  end

  defp config(overrides \\ []) do
    Keyword.merge([telemetry_prefix: [:cache_policy_test]], overrides)
  end

  defp generate(conn, representation, facts, mode \\ :auto, config \\ config()),
    do: CachePolicy.generate(conn, representation, facts, mode, config)

  describe "mode/2" do
    test "a mount without http_cache resolves to :validators" do
      assert CachePolicy.mode(:inherit, config()) == :validators
    end

    test "an inheriting source takes the mount's value" do
      assert CachePolicy.mode(:inherit, config(http_cache: :private)) == :private
    end

    test "a source value wins over the mount's" do
      assert CachePolicy.mode(:validators, config(http_cache: :public)) == :validators
      assert CachePolicy.mode(:private, config(http_cache: :public)) == :private
      assert CachePolicy.mode(:auto, config(http_cache: :validators)) == :auto
    end
  end

  test "generates Cache-Control and the representation's ETag" do
    assert %CacheHeaders{headers: headers, etag: ~s("ipr1-abc")} =
             generate(conn(:get, "/x"), representation(), facts())

    assert {"cache-control", @generated} in headers
    assert {"etag", ~s("ipr1-abc")} in headers
  end

  test ":validators emits the representation's ETag and no Cache-Control" do
    assert %CacheHeaders{headers: [{"etag", ~s("ipr1-abc")}], etag: ~s("ipr1-abc")} =
             generate(conn(:get, "/x"), representation(), facts(), :validators)
  end

  test ":validators withholds the ETag when the source denies storage" do
    assert %CacheHeaders{headers: [{"cache-control", "no-store"}], etag: nil} =
             generate(conn(:get, "/x"), representation(), facts(storage: :deny), :validators)
  end

  test ":private generates private Cache-Control without cookie storage inputs" do
    assert %CacheHeaders{headers: headers} =
             generate(conn(:get, "/x"), representation(), facts(), :private)

    assert {"cache-control", "private, max-age=31536000, immutable"} in headers
  end

  test ":auto turns private with cookie storage inputs and :public keeps it public" do
    config = config(storage_inputs: [{:cookie, "session"}])

    assert %CacheHeaders{headers: auto} =
             generate(conn(:get, "/x"), representation(), facts(), :auto, config)

    assert {"cache-control", "private, max-age=31536000, immutable"} in auto

    assert %CacheHeaders{headers: public} =
             generate(conn(:get, "/x"), representation(), facts(), :public, config)

    assert {"cache-control", @generated} in public
  end

  test "a host Set-Cookie suppresses generation" do
    conn = put_resp_cookie(conn(:get, "/x"), "session", "1")

    assert %CacheHeaders{headers: [], etag: nil} =
             generate(conn, representation(), facts())
  end

  test "a host Vary: * suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "*")

    assert %CacheHeaders{headers: [], etag: nil} =
             generate(conn, representation(), facts())
  end

  test "a representation Vary: * suppresses generation" do
    assert %CacheHeaders{headers: [], etag: nil} =
             generate(conn(:get, "/x"), representation(vary: ["*"]), facts())
  end

  test "a host no-store suppresses generation" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "no-store")

    assert %CacheHeaders{headers: [], etag: nil} =
             generate(conn, representation(), facts())
  end

  test "a host Cache-Control yields the ETag only" do
    conn = put_resp_header(conn(:get, "/x"), "cache-control", "max-age=60")

    assert %CacheHeaders{headers: [{"etag", ~s("ipr1-abc")}], etag: ~s("ipr1-abc")} =
             generate(conn, representation(), facts())
  end

  test "a host ETag is respected: none generated" do
    conn = put_resp_header(conn(:get, "/x"), "etag", ~s("host"))

    assert %CacheHeaders{headers: [{"cache-control", @generated}], etag: nil} =
             generate(conn, representation(), facts())
  end

  test "a non-GET/HEAD method generates nothing" do
    assert %CacheHeaders{headers: [], etag: nil} =
             generate(conn(:post, "/x"), representation(), facts())
  end

  test "representation Vary merges with a host Vary, deduplicated" do
    conn = put_resp_header(conn(:get, "/x"), "vary", "Origin")

    assert %CacheHeaders{representation_headers: [{"vary", "Origin, Accept"}]} =
             generate(conn, representation(vary: ["Accept"]), facts())
  end

  test "prepare telemetry fires with effective_mode, byte_identity, and etag" do
    attach_telemetry([[:cache_policy_test, :http_cache, :prepare]])

    generate(conn(:get, "/x"), representation(), facts())

    assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :prepare], %{}, metadata}
    assert metadata == %{effective_mode: :auto, byte_identity: :strong, etag: true}
  end

  test "degraded output is no-store and fires fallback telemetry" do
    attach_telemetry([[:cache_policy_test, :http_cache, :fallback, :no_store]])

    assert %CacheHeaders{headers: [{"cache-control", "no-store"}], etag: nil} =
             CachePolicy.generate(
               conn(:get, "/x"),
               representation(),
               facts(),
               :auto,
               config(),
               true
             )

    assert_receive {:telemetry_event, [:cache_policy_test, :http_cache, :fallback, :no_store],
                    %{}, metadata}

    assert metadata == %{
             source_mount: :web,
             source_kind: :url,
             reason: :detection_failed
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
