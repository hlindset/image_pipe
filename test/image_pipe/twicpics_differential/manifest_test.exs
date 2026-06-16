defmodule ImagePipe.Test.TwicpicsDifferential.ManifestTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.Manifest

  @manifest %{
    twicpics_api: "v1",
    baked_at: "2026-06-16T00:00:00Z",
    sources: %{
      "grid_4x4.png" => %{sha256: String.duplicate("a", 64), hosted_url: "https://h/x.png"}
    },
    entries: %{
      "cover_square" => %{
        authored_sha256: String.duplicate("b", 64),
        oracle_signature: String.duplicate("c", 64),
        fixture_filename: "cover_square.png",
        fixture_sha256: String.duplicate("d", 64),
        dims: {200, 200},
        bands: 4,
        cells: [{:cell, {0, 0}}, :padding]
      }
    }
  }

  test "write! then load! round-trips and validates" do
    path = Path.join(System.tmp_dir!(), "twic_manifest_#{System.unique_integer([:positive])}.exs")
    Manifest.write!(path, @manifest)
    assert Manifest.load!(path).entries["cover_square"].dims == {200, 200}
  end

  test "load! raises on a malformed entry (whole manifest, so the entry guard fires)" do
    path = Path.join(System.tmp_dir!(), "twic_bad_#{System.unique_integer([:positive])}.exs")
    bad = put_in(@manifest.entries["cover_square"].dims, "nope")
    File.write!(path, inspect(bad, limit: :infinity))
    # Top-level keys are intact, so this reaches validate_entry! and rejects `dims: "nope"`.
    assert_raise RuntimeError, ~r/cover_square/, fn -> Manifest.load!(path) end
  end

  test "oracle_signature depends on chain + suffix + source identity, not tol/verdict" do
    base = %{
      chain: "cover=200x200",
      suffix: "output=png/dpr=1",
      source_sha256: String.duplicate("a", 64)
    }

    s1 = Manifest.oracle_signature(base)
    s2 = Manifest.oracle_signature(base)
    s3 = Manifest.oracle_signature(%{base | chain: "cover=300x100"})
    assert s1 == s2 and s1 != s3
  end

  describe "fresh?/3 (the incremental-bake staleness predicate)" do
    setup do
      path = Path.join(System.tmp_dir!(), "twic_fx_#{System.unique_integer([:positive])}.png")
      File.write!(path, "pngbytes")
      sha = Manifest.file_sha256(path)
      entry = %{oracle_signature: "sig1", fixture_sha256: sha}
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path, sha: sha, entry: entry}
    end

    test "nil prior is never fresh (new case)", %{path: path} do
      refute Manifest.fresh?(nil, "sig1", path)
    end

    test "matching signature + present + matching hash is fresh", %{path: path, entry: entry} do
      assert Manifest.fresh?(entry, "sig1", path)
    end

    test "changed signature is stale", %{path: path, entry: entry} do
      refute Manifest.fresh?(entry, "sig2", path)
    end

    test "missing fixture file is stale", %{entry: entry} do
      refute Manifest.fresh?(entry, "sig1", "/no/such/fixture.png")
    end

    test "corrupted fixture (hash mismatch) is stale", %{path: path, entry: entry} do
      File.write!(path, "different")
      refute Manifest.fresh?(entry, "sig1", path)
    end
  end
end
