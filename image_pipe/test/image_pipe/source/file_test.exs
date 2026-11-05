defmodule ImagePipe.Source.FileTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.File, as: SourceFile
  alias ImagePipe.Source.Path, as: SourcePath
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

  # Only fetch reads bytes, so only fetch walks the path.
  test "a symlink that escapes the configured root is refused when fetched", %{root: root} do
    outside =
      Path.join(System.tmp_dir!(), "image-pipe-outside-#{System.unique_integer([:positive])}")

    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.jpg"), "secret")
    File.ln_s!(outside, Path.join(root, "images/outside"))
    on_exit(fn -> File.rm_rf!(outside) end)

    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    File.mkdir_p!(Path.join(root, "images/a/b"))
    File.ln_s!(outside, Path.join(root, "images/a/b/outside"))

    for segments <- [~w(images outside secret.jpg), ~w(images a b outside secret.jpg)] do
      assert {:ok, resolved} = SourceFile.resolve(%SourcePath{segments: segments}, opts, [])
      assert SourceFile.fetch(resolved, opts, []) == {:error, {:source, :denied_path}}
    end
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

  test "fetch reports paths that can't name a file as not found", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")

    for segments <- [
          ["images"],
          ["images", "cat.jpg", "x"],
          ["images", String.duplicate("a", 300)]
        ] do
      assert {:ok, resolved} = SourceFile.resolve(%SourcePath{segments: segments}, opts, [])
      assert SourceFile.fetch(resolved, opts, []) == {:error, {:source, :not_found}}
    end
  end

  test "fetch rejects a file over the body limit, immutable or not", %{root: root} do
    for stable <- [:auto, :immutable] do
      assert {:ok, opts} =
               SourceFile.validate_options(root: root, root_id: "fixture-root", stable: stable)

      assert {:ok, resolved} =
               SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

      assert SourceFile.fetch(resolved, opts, max_body_bytes: 1) ==
               {:error, {:source, :body_too_large}}
    end
  end

  @tag :file_permissions
  test "fetch reports an unsearchable parent directory as unreadable", %{root: root} do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")
    images = Path.join(root, "images")
    File.chmod!(images, 0o000)
    on_exit(fn -> File.chmod!(images, 0o755) end)

    assert {:ok, resolved} =
             SourceFile.resolve(%SourcePath{segments: ["images", "cat.jpg"]}, opts, [])

    assert SourceFile.fetch(resolved, opts, []) == {:error, {:source, :unreadable}}
  end

  describe "with stat evidence from an earlier fetch" do
    setup %{root: root} do
      {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")
      runtime = [clock: fn -> System.os_time(:second) + 10 end]
      {:ok, cat} = SourceFile.resolve(%SourcePath{segments: ~w(images cat.jpg)}, opts, [])
      {:ok, %Response{origin: evidence}} = SourceFile.fetch(cat, opts, runtime)
      %{opts: opts, cat: cat, runtime: [source_validation: evidence] ++ runtime}
    end

    # A matching stat names a file the walk already found inside the root, so
    # the walk is skipped: a link it would refuse still reaches that file.
    test "a matching stat skips the path walk", ctx do
      File.ln_s!(Path.join(ctx.root, "images/cat.jpg"), Path.join(ctx.root, "images/alias.jpg"))
      {:ok, alias} = SourceFile.resolve(%SourcePath{segments: ~w(images alias.jpg)}, ctx.opts, [])

      assert {:not_modified, _origin} = SourceFile.fetch(ctx.cat, ctx.opts, ctx.runtime)
      assert {:not_modified, _origin} = SourceFile.fetch(alias, ctx.opts, ctx.runtime)
      assert SourceFile.fetch(alias, ctx.opts, []) == {:error, {:source, :denied_path}}
    end

    test "a parent directory replaced by a link out of the root is refused", ctx do
      outside =
        Path.join(System.tmp_dir!(), "image-pipe-outside-#{System.unique_integer([:positive])}")

      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "cat.jpg"), "secret")
      on_exit(fn -> File.rm_rf!(outside) end)
      File.rename!(Path.join(ctx.root, "images"), Path.join(ctx.root, "kept"))
      File.ln_s!(outside, Path.join(ctx.root, "images"))

      assert SourceFile.fetch(ctx.cat, ctx.opts, ctx.runtime) ==
               {:error, {:source, :denied_path}}
    end

    test "the body limit still applies", ctx do
      assert SourceFile.fetch(ctx.cat, ctx.opts, [max_body_bytes: 1] ++ ctx.runtime) ==
               {:error, {:source, :body_too_large}}
    end
  end

  test "file source defaults to content identity with internal cache in auto mode", %{
    root: root
  } do
    assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")
    source = %SourcePath{segments: ["images", "cat.jpg"]}

    assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

    assert resolved.internal_cache == :enabled
    assert resolved.http_cache == :inherit
    assert resolved.cache_semantics.stable? == false
    assert resolved.cache_semantics.byte_identity == :content
  end

  test "immutable file source derives strong byte identity", %{root: root} do
    assert {:ok, opts} =
             SourceFile.validate_options(root: root, root_id: "fixture-root", stable: :immutable)

    source = %SourcePath{segments: ["images", "cat.jpg"]}

    assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

    assert resolved.internal_cache == :enabled
    assert resolved.cache_semantics.stable? == true
    assert {:strong, seed} = resolved.cache_semantics.byte_identity
    assert seed[:root] == "fixture-root"
    assert seed[:path] == ["images", "cat.jpg"]
  end
end
