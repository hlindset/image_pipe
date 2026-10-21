defmodule ImagePipeServer.Stats.DiskTest do
  use ExUnit.Case, async: true

  alias ImagePipeServer.Stats.Disk

  @moduletag :tmp_dir

  @df_output """
  Filesystem 1024-blocks Used Available Capacity Mounted on
  /dev/disk1 1000 400 600 40% /cache root
  """

  # A `df` stand-in that answers as the `mode` file says: `ok` prints
  # `@df_output`, `warn` also prints a warning to stderr, `fail` exits 1,
  # and `hang` waits until a `release` file exists, then answers `ok`. The first `df` runs as the process starts, in
  # the mode the test's `:mode` tag gives, and setup waits for it unless it
  # hangs.
  setup %{tmp_dir: dir} = context do
    mode = Map.get(context, :mode, "ok")
    File.write!(Path.join(dir, "output"), @df_output)
    File.write!(Path.join(dir, "mode"), mode)
    df = Path.join(dir, "df")

    File.write!(df, """
    #!/bin/sh
    dir=#{dir}
    echo "$@" >> "$dir/calls"
    if [ "$(cat "$dir/mode")" = hang ]; then
      while [ ! -e "$dir/release" ]; do sleep 0.01; done
    fi
    [ "$(cat "$dir/mode")" = fail ] && exit 1
    cat "$dir/output"
    [ "$(cat "$dir/mode")" = warn ] && echo "df: /other: Permission denied" >&2
    exit 0
    """)

    File.chmod!(df, 0o755)
    on_exit(fn -> File.touch!(Path.join(dir, "release")) end)

    name = Module.concat(__MODULE__, "D#{System.unique_integer([:positive])}")
    root = Path.join(dir, "cache root")
    pid = start_supervised!({Disk, name: name, roots: [root], command: df, interval: :infinity})
    if mode != "hang", do: wait(pid, Map.fetch!(:sys.get_state(pid).running, root))

    %{dir: dir, name: name, root: root, pid: pid}
  end

  @sizes %{disk_free_bytes: 600 * 1024, disk_total_bytes: 1000 * 1024}

  @tag mode: "hang"
  test "reports nothing before the first df ends", %{name: name, root: root} do
    assert Disk.read(name, root) == %{
             disk_free_bytes: nil,
             disk_total_bytes: nil,
             disk_age_seconds: nil
           }
  end

  test "reports the sizes the last df read, with their age", %{name: name, root: root, pid: pid} do
    assert Disk.read(name, root) == Map.put(@sizes, :disk_age_seconds, 0)
    assert calls(pid) == ["-kP -- " <> root]
  end

  test "overlapping reads all get the sizes", %{name: name, root: root} do
    reads =
      1..8
      |> Task.async_stream(fn _ -> Disk.read(name, root) end, max_concurrency: 8)
      |> Enum.map(fn {:ok, read} -> read end)

    assert Enum.all?(reads, &(Map.take(&1, [:disk_free_bytes, :disk_total_bytes]) == @sizes))
  end

  test "a failed df keeps the last good sizes", %{name: name, root: root, dir: dir, pid: pid} do
    File.write!(Path.join(dir, "mode"), "fail")
    refresh_and_wait(pid, root)

    assert Map.take(Disk.read(name, root), [:disk_free_bytes, :disk_total_bytes]) == @sizes
    assert length(calls(pid)) == 2
  end

  @tag mode: "warn"
  test "reads the sizes when df also prints a warning", %{name: name, root: root} do
    assert Map.take(Disk.read(name, root), [:disk_free_bytes, :disk_total_bytes]) == @sizes
  end

  test "unreadable df output keeps the last good sizes", %{
    name: name,
    root: root,
    dir: dir,
    pid: pid
  } do
    File.write!(Path.join(dir, "output"), "nonsense\n")
    refresh_and_wait(pid, root)

    assert Map.take(Disk.read(name, root), [:disk_free_bytes, :disk_total_bytes]) == @sizes
  end

  test "a slow df keeps the last good sizes and starts no other for its root", %{
    name: name,
    root: root,
    dir: dir,
    pid: pid
  } do
    File.write!(Path.join(dir, "mode"), "hang")
    worker = refresh(pid, root)

    assert Map.take(Disk.read(name, root), [:disk_free_bytes, :disk_total_bytes]) == @sizes

    assert refresh(pid, root) == worker

    File.write!(Path.join(dir, "output"), String.replace(@df_output, "600", "500"))
    File.touch!(Path.join(dir, "release"))
    wait(pid, worker)

    assert Disk.read(name, root).disk_free_bytes == 500 * 1024
    assert length(calls(pid)) == 2
  end

  # Sends the timer's message and returns the `df` worker for `root`. The
  # state is read right after the refresh, before that worker can end.
  defp refresh(pid, root) do
    send(pid, :refresh)
    Map.fetch!(:sys.get_state(pid).running, root)
  end

  defp refresh_and_wait(pid, root), do: wait(pid, refresh(pid, root))

  defp wait(pid, worker) do
    ref = Process.monitor(worker)
    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 5_000
    _ = :sys.get_state(pid)
  end

  defp calls(pid) do
    %{command: df} = :sys.get_state(pid)
    df |> Path.dirname() |> Path.join("calls") |> File.read!() |> String.split("\n", trim: true)
  end
end
