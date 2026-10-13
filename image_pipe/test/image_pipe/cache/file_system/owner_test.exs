defmodule ImagePipe.Cache.FileSystem.OwnerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Owner
  alias ImagePipe.Cache.FileSystem.OwnerWatch
  alias ImagePipe.Cache.FileSystem.Root

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    on_exit(fn -> Owner.accept(root) end)
    {:ok, path: Path.join(root, Owner.file_name())}
  end

  test "claims a root nobody owns", %{tmp_dir: root, path: path} do
    start_supervised!({Root, root: root, max_size_bytes: 1_000_000, host: "this-host"})
    assert host(path) == "this-host"
    refute MapSet.member?(Owner.refused(), root)
  end

  test "concurrent refusals and acceptances all land", %{tmp_dir: root} do
    dirs = for n <- 1..200, do: Path.join(root, "concurrent-#{n}")
    on_exit(fn -> Enum.each(dirs, &Owner.accept/1) end)

    dirs
    |> Task.async_stream(&Owner.refuse/1, max_concurrency: 50)
    |> Stream.run()

    assert Enum.all?(dirs, &MapSet.member?(Owner.refused(), &1))

    dirs
    |> Task.async_stream(&Owner.accept/1, max_concurrency: 50)
    |> Stream.run()

    refute Enum.any?(dirs, &MapSet.member?(Owner.refused(), &1))
  end

  test "a crashed cache process restarts without giving the root up", %{tmp_dir: root} do
    root_pid = start_supervised!({Root, root: root, max_size_bytes: 1_000_000, host: "this-host"})
    root_ref = Process.monitor(root_pid)
    owner = child(root_pid, Owner)
    admission = admission(root)
    ref = Process.monitor(admission)

    Process.exit(admission, :kill)
    assert_receive {:DOWN, ^ref, :process, _pid, :killed}

    assert restarted_admission(root, admission) != admission
    assert child(root_pid, Owner) == owner
    refute_received {:DOWN, ^root_ref, :process, _pid, _reason}
  end

  test "a second cache on a root this VM runs fails to start", %{tmp_dir: root, path: path} do
    start_supervised!({Root, root: root, max_size_bytes: 1_000_000, host: "this-host"})
    claimed = File.read!(path)

    assert {:error, {:already_started, _pid}} =
             start_supervised(
               Supervisor.child_spec({Root, root: root, max_size_bytes: 1_000_000}, id: :second)
             )

    assert File.read!(path) == claimed
    refute MapSet.member?(Owner.refused(), root)
  end

  test "an instance claims its cache roots while it runs", %{tmp_dir: root, path: path} do
    name = :"#{__MODULE__}.Instance#{System.unique_integer([:positive])}"

    start_supervised!(
      {ImagePipe, name: name, sources: [], cache: [root: root, max_size_bytes: 1_000_000]}
    )

    assert File.exists?(path)

    :ok = stop_supervised(name)
    refute File.exists?(path)
  end

  test "takes over a root this host owned before a restart", %{tmp_dir: root, path: path} do
    File.write!(path, "this-host\nold-token\n7\n")

    start_supervised!({Root, root: root, max_size_bytes: 1_000_000, host: "this-host"})
    refute File.read!(path) =~ "old-token"
  end

  describe "a root another node's file names" do
    setup %{tmp_dir: root, path: path} do
      File.write!(path, "other-host\ntoken\n0\n")

      {root_sup, log} =
        with_log(fn ->
          start_supervised!(
            {Root,
             root: root,
             max_size_bytes: 1_000_000,
             host: "this-host",
             watch_ms: 60_000,
             heartbeat_ms: 10}
          )
        end)

      [{_id, watch, _type, [OwnerWatch]}] = Supervisor.which_children(root_sup)
      %{root_sup: root_sup, watch: watch, log: log}
    end

    test "is refused at once, and only watched", ctx do
      assert ctx.log =~ ~s(belongs to host "other-host")
      assert MapSet.member?(Owner.refused(), ctx.tmp_dir)
      assert host(ctx.path) == "other-host"
    end

    test "stays refused while the other node keeps updating it", ctx do
      File.write!(ctx.path, "other-host\ntoken\n1\n")

      log =
        capture_log(fn ->
          send(ctx.watch, :check)
          _ = :sys.get_state(ctx.watch)
        end)

      assert log =~ ~s(host "other-host" is using cache root)
      assert MapSet.member?(Owner.refused(), ctx.tmp_dir)
      assert host(ctx.path) == "other-host"
    end

    test "is taken over once the file stops changing", ctx do
      assert_takes_over(ctx)
    end

    test "is taken over once the file is gone", ctx do
      File.rm!(ctx.path)
      assert_takes_over(ctx)
    end
  end

  test "a node that lost its root on its own host doesn't take it back", ctx do
    {:ok, claim} = Owner.claim(ctx.tmp_dir, host: "this-host")
    start_supervised!({Owner, claim}, id: :other)
    Owner.refuse(ctx.tmp_dir)

    capture_log(fn ->
      root_sup =
        start_supervised!({Root, root: ctx.tmp_dir, max_size_bytes: 1_000_000, host: "this-host"})

      assert [{_id, _pid, _type, [OwnerWatch]}] = Supervisor.which_children(root_sup)
    end)

    assert File.read!(ctx.path) =~ claim.token
  end

  test "a root taken over is refused, and its owner stops", ctx do
    {:ok, claim} = Owner.claim(ctx.tmp_dir, host: "this-host")
    pid = start_supervised!({Owner, claim}, restart: :temporary)
    ref = Process.monitor(pid)
    File.write!(ctx.path, "other-host\ntoken\n0\n")

    log =
      capture_log(fn ->
        send(pid, :heartbeat)
        assert_receive {:DOWN, ^ref, :process, ^pid, {:shutdown, :root_taken_over}}
      end)

    assert log =~ ~s(host "other-host" took over cache root)
    assert MapSet.member?(Owner.refused(), ctx.tmp_dir)
    assert File.read!(ctx.path) == "other-host\ntoken\n0\n"
  end

  test "rewrites the owner file on each heartbeat", %{tmp_dir: root, path: path} do
    {:ok, claim} = Owner.claim(root, host: "this-host")
    pid = start_supervised!({Owner, claim})
    claimed = File.read!(path)
    File.rm!(path)

    send(pid, :heartbeat)
    _ = :sys.get_state(pid)
    assert host(path) == "this-host"
    refute File.read!(path) == claimed
  end

  test "a clean stop gives the root up", %{tmp_dir: root, path: path} do
    {:ok, claim} = Owner.claim(root, host: "this-host")
    start_supervised!({Owner, claim})
    :ok = stop_supervised(Owner)
    refute File.exists?(path)
  end

  test "a stop leaves an owner file another node wrote since", %{tmp_dir: root, path: path} do
    {:ok, claim} = Owner.claim(root, host: "this-host")
    start_supervised!({Owner, claim})
    File.write!(path, "other-host\ntoken\n0\n")
    :ok = stop_supervised(Owner)
    assert File.read!(path) == "other-host\ntoken\n0\n"
  end

  # The watch takes the root over and stops, which stops its Root. The test
  # supervisor restarts the Root, which starts the cache with the claim the
  # watch handed off.
  defp assert_takes_over(ctx) do
    test_sup =
      ctx.root_sup
      |> Process.info(:dictionary)
      |> elem(1)
      |> Keyword.fetch!(:"$ancestors")
      |> hd()

    ref = Process.monitor(ctx.root_sup)
    send(ctx.watch, :check)
    assert_receive {:DOWN, ^ref, :process, _pid, _reason}

    restarted =
      restarted_root(test_sup, ctx.root_sup, System.monotonic_time(:millisecond) + 5_000)

    taken = File.read!(ctx.path)

    assert {Owner, _pid, :worker, [Owner]} =
             List.keyfind(Supervisor.which_children(restarted), Owner, 0)

    assert host(ctx.path) == "this-host"
    assert File.read!(ctx.path) =~ taken |> String.split("\n") |> Enum.at(1)
    refute MapSet.member?(Owner.refused(), ctx.tmp_dir)
  end

  # The Root's exit reaches the test supervisor apart from this process's
  # calls, so each call lets it handle the exit until the restart shows.
  defp restarted_root(test_sup, old, deadline) do
    _ = :sys.get_state(test_sup)

    restarted =
      for {{Root, _dir}, pid, _type, _modules} <- Supervisor.which_children(test_sup),
          is_pid(pid) and pid != old,
          do: pid

    case restarted do
      [pid] ->
        pid

      [] ->
        assert System.monotonic_time(:millisecond) < deadline, "Root wasn't restarted"
        restarted_root(test_sup, old, deadline)
    end
  end

  defp host(path), do: path |> File.read!() |> String.split("\n") |> hd()

  defp child(supervisor, id) do
    {^id, pid, _type, _modules} = List.keyfind(Supervisor.which_children(supervisor), id, 0)
    pid
  end

  defp admission(root) do
    [{pid, _value}] = Registry.lookup(FileSystem.registry_name(root), root)
    pid
  end

  # The cache's supervisor restarts Admission after its exit, which this
  # process sees first.
  defp restarted_admission(root, crashed) do
    case Registry.lookup(FileSystem.registry_name(root), root) do
      [{pid, _value}] when pid != crashed -> pid
      _crashed_or_restarting -> restarted_admission(root, crashed)
    end
  end
end
