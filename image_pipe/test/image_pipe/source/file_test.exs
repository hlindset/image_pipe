defmodule ImagePipe.Source.FileTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source.File, as: SourceFile
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "image-pipe-file-source-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(tmp, "images"))
    File.write!(Path.join(tmp, "images/cat.jpg"), "image bytes")
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, root: tmp}
  end

  test "resolve keeps absolute root path out of identity", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert {:ok, %Resolved{} = resolved} =
             SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

    assert resolved.identity == [
             kind: :path,
             adapter: :path,
             root: "fixture-root",
             path: ["images", "cat.jpg"]
           ]

    refute inspect(resolved.identity) =~ root
  end

  test "resolve rejects traversal before fetch", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert SourceFile.resolve(%SourcePath{segments: ["..", "secret.jpg"]}, opts, []) ==
             {:error, {:source, :denied_path}}
  end

  test "resolve rejects symlinks that escape the configured root", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "image-pipe-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.jpg"), "secret")
    File.ln_s!(outside, Path.join(root, "images/outside"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert SourceFile.resolve(
             %SourcePath{segments: ["images", "outside", "secret.jpg"]},
             opts,
             []
           ) ==
             {:error, {:source, :denied_path}}
  end

  test "fetch rechecks path safety after cache lookup can delay the open", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "image-pipe-outside-#{System.unique_integer([:positive])}")

    safe_path = Path.join(root, "images/cat.jpg")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.jpg"), "secret")
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert {:ok, resolved} =
             SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

    File.rm!(safe_path)
    File.ln_s!(Path.join(outside, "secret.jpg"), safe_path)

    assert SourceFile.fetch(resolved, opts, []) == {:error, {:source, :denied_path}}
  end

  test "fetch returns the resolved file path", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert {:ok, resolved} =
             SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

    assert {:ok, %Response{path: path, stream: nil}} =
             SourceFile.fetch(resolved, opts, max_body_bytes: 20)

    assert path == Path.join(root, "images/cat.jpg")
    assert File.read!(path) == "image bytes"
  end

  test "fetch returns safe source errors for missing files", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    assert {:ok, resolved} =
             SourceFile.resolve(%SourcePath{segments: ["images", "missing.jpg"]}, opts, [])

    assert SourceFile.fetch(resolved, opts, []) == {:error, {:source, :not_found}}
  end

  test "file source defaults to not stable and disables internal cache in auto mode", %{
    root: root
  } do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")
    source = %SourcePath{segments: ["images", "cat.jpg"]}

    assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

    assert resolved.internal_cache == :disabled
    assert resolved.http_cache == :inherit
    assert resolved.cache_semantics.stable? == false
    assert resolved.cache_semantics.byte_identity == :none
  end

  test "file source trusted stability derives strong byte identity", %{root: root} do
    assert {:ok, opts} =
             SourceFile.validate_options(root: root, root_id: "fixture-root", stable: :trusted)

    source = %SourcePath{segments: ["images", "cat.jpg"]}

    assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

    assert resolved.internal_cache == :enabled
    assert resolved.cache_semantics.stable? == true
    assert {:strong, seed} = resolved.cache_semantics.byte_identity
    assert seed[:root] == "fixture-root"
    assert seed[:path] == ["images", "cat.jpg"]
  end
end
