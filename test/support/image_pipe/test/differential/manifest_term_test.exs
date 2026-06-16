defmodule ImagePipe.Test.Differential.ManifestTermTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.Differential.ManifestTerm

  test "sorted_map_literal renders nested maps with sorted keys" do
    out = ManifestTerm.sorted_map_literal(%{"b" => %{z: 1, a: 2}, "a" => 3})
    assert out == ~s|%{"a" => 3,"b" => %{a: 2,z: 1}}|
  end

  test "authored_sha256 is stable across key order and ignores absent keys" do
    keys = [:chain, :verdict]
    a = ManifestTerm.authored_sha256(%{verdict: :equal, chain: "x", extra: 9}, keys)
    b = ManifestTerm.authored_sha256(%{chain: "x", verdict: :equal}, keys)
    assert a == b and byte_size(a) == 64
  end

  test "file_sha256 hashes bytes (lowercase hex)" do
    path = Path.join(System.tmp_dir!(), "mt_#{System.unique_integer([:positive])}.bin")
    File.write!(path, "abc")

    assert ManifestTerm.file_sha256(path) ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
