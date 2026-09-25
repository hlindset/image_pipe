defmodule ImagePipe.Cache.SharedFileSystem.LifecycleTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Cache.SharedFileSystem
  alias ImagePipe.Cache.SharedFileSystem.IO, as: CacheIO
  alias ImagePipe.Cache.SharedFileSystem.{Lifecycle, Partition, Runtime}

  @tag capture_log: true
  test "lifecycle reports creation, healthy heartbeats, retirement recovery and helper loss" do
    root = Path.join(System.tmp_dir!(), "shared_lifecycle_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    prefix = [__MODULE__, :lifecycle]
    id = {__MODULE__, make_ref()}
    event = prefix ++ [:cache, :shared_lifecycle, :stop]

    :ok =
      :telemetry.attach(
        id,
        event,
        fn _, _, meta, pid -> send(pid, {:lifecycle, meta}) end,
        self()
      )

    on_exit(fn -> :telemetry.detach(id) end)

    start_supervised!(
      {SharedFileSystem,
       name: __MODULE__,
       root: Path.join(root, "shared"),
       local_root: Path.join(root, "local"),
       telemetry_prefix: prefix}
    )

    assert_receive {:lifecycle, %{result: :ok, operation: :created}}
    {:ok, before} = Runtime.context(__MODULE__)
    restart_lifecycle()
    assert_receive {:lifecycle, %{result: :ok, operation: :heartbeat}}

    assert {:ok, {:ok, _}} =
             CacheIO.run(before.pool, {Partition, :retire, [before.partition]}, 0, 1_000)

    restart_lifecycle()
    assert_receive {:lifecycle, %{result: :ok, operation: :rotated}}
    {:ok, after_rotation} = Runtime.context(__MODULE__)
    refute after_rotation.partition.id == before.partition.id

    assert {:error, :unavailable} = CacheIO.run(before.pool, {:erlang, :halt, []}, 0, 1_000)
    restart_lifecycle()
    assert_receive {:lifecycle, %{result: :cache_error, operation: :unavailable} = metadata}
    assert Map.keys(metadata) |> Enum.sort() == [:operation, :result, :telemetry_span_context]
    assert {:error, :unavailable} = Runtime.context(__MODULE__)
  end

  defp restart_lifecycle do
    :ok = Supervisor.terminate_child(__MODULE__, Lifecycle)
    {:ok, _} = Supervisor.restart_child(__MODULE__, Lifecycle)
  end
end
