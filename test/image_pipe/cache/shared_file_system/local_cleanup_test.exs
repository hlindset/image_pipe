defmodule ImagePipe.Cache.SharedFileSystem.LocalCleanupTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.Entry.Metadata
  alias ImagePipe.Cache.SharedFileSystem.{Generation, Partition}
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Test.SharedCrashProbe

  @script Path.expand("../../../../scripts/shared-cache-clean-local.sh", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "shared_cleanup_#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  @tag capture_log: true
  test "offline cleanup reclaims a crashed BEAM's readers and preserves shared entries", ctx do
    shared = Path.join(ctx.root, "shared")
    local = Path.join(ctx.root, "local")
    other = Path.join(ctx.root, "other-local")
    File.mkdir!(other)
    File.write!(Path.join(other, "keep"), "unrelated reader")
    {:ok, partition} = Partition.create(shared)
    source = Path.join(ctx.root, "source")
    File.write!(source, "encoded cached bytes")
    pool = start_supervised!(CacheIO) |> CacheIO.client()
    limits = %{body: 128, metadata: 1_024}

    metadata = %Metadata{
      content_type: "image/png",
      headers: [],
      created_at: ~U[2026-09-25 00:00:00Z],
      representation: {:image, :png},
      output_format: :png
    }

    assert {:ok, location} =
             Generation.publish(
               pool,
               Partition.plan(partition, :outputs, String.duplicate("a", 64)),
               source,
               metadata,
               limits,
               5_000
             )

    first = peer(:first)

    {os_pid, reader, ^metadata} =
      :peer.call(first, SharedCrashProbe, :acquire, [shared, local, location], 15_000)

    assert File.read!(reader) == "encoded cached bytes"
    down = Process.monitor(first)
    assert {_, 0} = System.cmd("kill", ["-KILL", os_pid])
    assert_receive {:DOWN, ^down, :process, ^first, _}, 5_000
    assert File.read!(reader) == "encoded cached bytes"

    assert {_, 0} = clean(local)
    assert File.ls!(local) == []
    assert File.read!(Path.join(other, "keep")) == "unrelated reader"
    assert File.read!(Path.join(location.path, "body")) == "encoded cached bytes"

    second = peer(:second)

    {_os_pid, replacement, ^metadata} =
      :peer.call(second, SharedCrashProbe, :acquire, [shared, local, location], 15_000)

    assert File.read!(replacement) == "encoded cached bytes"
    refute replacement == reader
    stop_supervised!(:second)
    assert {_, 0} = clean(local)
  end

  test "cleanup refuses unexpected roots before deleting recognized entries", ctx do
    incarnation = Path.join(ctx.root, String.duplicate("a", 32))
    File.mkdir!(incarnation)
    body = Path.join(incarnation, "body")
    File.write!(body, "keep until preflight passes")
    File.write!(Path.join(ctx.root, "unrelated"), "keep")
    assert {_, 65} = clean(ctx.root)
    assert File.exists?(body)

    File.rm!(Path.join(ctx.root, "unrelated"))
    linked = Path.join(ctx.root, String.duplicate("b", 32))
    File.ln_s!(incarnation, linked)
    assert {_, 65} = clean(ctx.root)
    assert File.exists?(body)
    assert {_, 64} = clean(linked)
    assert {_, 64} = clean(linked <> "/")
    assert {_, 64} = clean(linked <> "/.")
    assert {_, 64} = System.cmd("sh", [@script, ctx.root], stderr_to_stdout: true)
  end

  test "cleanup leaves nested symlink targets and the root itself intact", ctx do
    local = Path.join(ctx.root, "local")
    reader = Path.join([local, String.duplicate("a", 32), String.duplicate("b", 32)])
    File.mkdir_p!(reader)
    outside = Path.join(ctx.root, "keep")
    File.write!(outside, "outside the local root")
    File.ln_s!(outside, Path.join(reader, "body"))
    assert {_, 0} = clean(local)
    assert File.ls!(local) == []
    assert File.read!(outside) == "outside the local root"
    assert {_, 0} = clean(local)
    assert {_, 0} = clean(Path.join(ctx.root, "not-created"))
  end

  test "deletion failures remain visible until a successful retry", ctx do
    incarnation = Path.join(ctx.root, String.duplicate("a", 32))
    File.mkdir!(incarnation)
    body = Path.join(incarnation, "body")
    File.write!(body, "cannot remove yet")
    File.chmod!(incarnation, 0o500)

    try do
      {_diagnostic, status} = clean(ctx.root)
      assert status != 0
      assert File.read!(body) == "cannot remove yet"
    after
      File.chmod!(incarnation, 0o700)
    end

    assert {_, 0} = clean(ctx.root)
    assert File.ls!(ctx.root) == []
  end

  defp clean(root), do: System.cmd("sh", [@script, "--stopped", root], stderr_to_stdout: true)

  defp peer(id) do
    paths = Enum.flat_map(:code.get_path(), &[~c"-pa", &1])

    opts = %{
      connection: :standard_io,
      peer_down: :crash,
      shutdown: :halt,
      wait_boot: 5_000,
      args: [~c"+S", ~c"1:1", ~c"+SDio", ~c"1", ~c"+SDcpu", ~c"1"] ++ paths
    }

    start_supervised!(%{id: id, start: {:peer, :start_link, [opts]}, restart: :temporary})
  end
end
