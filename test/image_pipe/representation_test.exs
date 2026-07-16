defmodule ImagePipe.RepresentationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  import Plug.Test

  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  defp material(overrides \\ []) do
    base = [
      representation: [groups: [], terminal: :image, selection: {:explicit, :webp}],
      storage_only: [cachebuster: nil],
      dialect_behavior: {ImagePipe.Dialect.Native, 1},
      vary_header_names: ["Accept"]
    ]

    struct!(IdentityMaterial, Keyword.merge(base, overrides))
  end

  defp source_identity,
    do: [kind: :path, adapter: :path, root: "default", path: ["images", "cat.jpg"]]

  # These tests exercise the strong-byte-identity path (ETag present); the
  # `:none` withholding contract has its own test below and the wire-level
  # observable test in `byte_identity_cache_headers_test.exs`.
  defp build(source_identity, material),
    do: Representation.build(source_identity, material, {:strong, source_identity})

  test "same material builds an equal key hash and etag" do
    a = build(source_identity(), material())
    b = build(source_identity(), material())

    assert a.cache_key.hash == b.cache_key.hash
    assert a.etag == b.etag
  end

  test "cache_key hash and etag have the expected shapes" do
    rep = build(source_identity(), material())

    assert rep.cache_key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert rep.etag =~ ~r/\A"ipr1-[A-Za-z0-9_-]+"\z/
  end

  test "a storage_only change moves the key but not the etag" do
    a = build(source_identity(), material(storage_only: [cachebuster: nil]))
    b = build(source_identity(), material(storage_only: [cachebuster: "v2"]))

    assert a.cache_key.hash != b.cache_key.hash
    assert a.etag == b.etag
  end

  test "a representation change moves both the key and the etag" do
    a = build(source_identity(), material())

    b =
      build(
        source_identity(),
        material(representation: [groups: [], terminal: :blurhash])
      )

    assert a.cache_key.hash != b.cache_key.hash
    assert a.etag != b.etag
  end

  test "a dialect_behavior epoch bump moves both the key and the etag" do
    a =
      build(
        source_identity(),
        material(dialect_behavior: {ImagePipe.Dialect.Native, 1})
      )

    b =
      build(
        source_identity(),
        material(dialect_behavior: {ImagePipe.Dialect.Native, 2})
      )

    assert a.cache_key.hash != b.cache_key.hash
    assert a.etag != b.etag
  end

  test "a :none byte_identity withholds the ETag, marks no_store?, and computes the key" do
    rep = Representation.build(source_identity(), material(), :none)

    assert rep.etag == nil
    assert rep.no_store? == true
    assert rep.cache_key.hash =~ ~r/\A[0-9a-f]{64}\z/
    assert Representation.response_headers(rep) == [{"cache-control", "no-store"}]
  end

  test "a strong byte_identity emits the ETag as its response header" do
    rep = Representation.build(source_identity(), material(), {:strong, source_identity()})

    assert rep.no_store? == false
    assert Representation.response_headers(rep) == [{"etag", rep.etag}]
  end

  test "key data carries the core execution epoch" do
    rep = build(source_identity(), material())

    assert rep.cache_key.data[:core_epoch] == 1
  end

  test "vary echoes vary_header_names and nothing else" do
    rep =
      build(
        source_identity(),
        material(vary_header_names: ["Accept", "Save-Data"])
      )

    assert rep.vary == ["Accept", "Save-Data"]
  end

  describe "storage_inputs/2" do
    test "a header contributes its value to storage_only and its name to vary" do
      conn = :get |> conn("/") |> Plug.Conn.put_req_header("save-data", "on")

      {storage_only, vary} = Representation.storage_inputs(conn, [{:header, "Save-Data"}])

      assert Keyword.fetch!(storage_only, :headers) == [{"save-data", ["on"]}]
      assert Keyword.fetch!(storage_only, :cookies) == []
      assert vary == ["save-data"]
    end

    test "a cookie contributes its value to storage_only and nothing to vary" do
      conn = :get |> conn("/") |> put_req_cookie("session", "abc")

      {storage_only, vary} = Representation.storage_inputs(conn, [{:cookie, "session"}])

      assert Keyword.fetch!(storage_only, :cookies) == [{"session", "abc"}]
      assert Keyword.fetch!(storage_only, :headers) == []
      assert vary == []
    end

    test "a missing cookie is omitted from storage_only" do
      conn = conn(:get, "/")

      {storage_only, _vary} = Representation.storage_inputs(conn, [{:cookie, "session"}])

      assert Keyword.fetch!(storage_only, :cookies) == []
    end

    test "header names are normalized, deduplicated, and deterministically ordered" do
      conn = :get |> conn("/") |> Plug.Conn.put_req_header("save-data", "on")

      {storage_only_a, vary_a} =
        Representation.storage_inputs(conn, [{:header, "Save-Data"}, {:header, "save-data"}])

      {storage_only_b, vary_b} =
        Representation.storage_inputs(conn, [{:header, "save-data"}, {:header, "SAVE-DATA"}])

      assert vary_a == ["save-data"]
      assert vary_a == vary_b
      assert storage_only_a == storage_only_b
    end

    test "output order does not depend on the configured list's order" do
      conn =
        :get
        |> conn("/")
        |> Plug.Conn.put_req_header("save-data", "on")
        |> Plug.Conn.put_req_header("dpr", "2")

      forward = Representation.storage_inputs(conn, [{:header, "save-data"}, {:header, "dpr"}])
      backward = Representation.storage_inputs(conn, [{:header, "dpr"}, {:header, "save-data"}])

      assert forward == backward
    end
  end

  property "ETag never varies with storage_only" do
    check all storage_only <- storage_only_generator(), max_runs: 50 do
      a = build(source_identity(), material(storage_only: storage_only))
      b = build(source_identity(), material(storage_only: [other: :value]))

      assert a.etag == b.etag
    end
  end

  defp storage_only_generator do
    map(
      map_of(atom(:alphanumeric), one_of([string(:alphanumeric), integer(), boolean()]),
        max_length: 4
      ),
      &Enum.into(&1, [])
    )
  end
end
