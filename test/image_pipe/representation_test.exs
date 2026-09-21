defmodule ImagePipe.RepresentationTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias ImagePipe.Representation
  alias ImagePipe.Representation.IdentityMaterial

  defp material(overrides \\ []) do
    base = [
      representation: [groups: [], terminal: :image, selection: {:explicit, :webp}],
      storage_only: [cachebuster: nil],
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

  test "a source_identity change moves both the key and the etag" do
    a = build(source_identity(), material())
    b = build(Keyword.put(source_identity(), :root, "other"), material())

    assert a.cache_key.hash != b.cache_key.hash
    assert a.etag != b.etag
  end

  test "a source byte revision moves the key and etag for the same logical source" do
    a = Representation.build(source_identity(), material(), {:strong, "revision-1"})
    b = Representation.build(source_identity(), material(), {:strong, "revision-2"})

    assert a.cache_key.hash != b.cache_key.hash
    assert a.etag != b.etag
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
