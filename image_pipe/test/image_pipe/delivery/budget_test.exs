defmodule ImagePipe.Delivery.BudgetTest do
  # The budget is VM-wide, so these tests run alone.
  use ExUnit.Case, async: false

  alias ImagePipe.Delivery.Budget
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Telemetry.RequestContext

  @mb 1024 * 1024

  setup %{test: test} do
    tasks = start_supervised!({Task.Supervisor, []})
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0})
    prefix = [__MODULE__, test]
    handler = make_ref()

    :telemetry.attach(
      handler,
      prefix ++ [:processing, :execute, :stop],
      &__MODULE__.stopped/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    %{
      tasks: tasks,
      pool: pool,
      config: [processing_pool: pool, telemetry_prefix: prefix],
      held: {Budget.held(:memory), Budget.held(:spool)}
    }
  end

  def stopped(_event, _measurements, metadata, test),
    do: send(test, {:processing_stopped, metadata.result})

  @tag :tmp_dir
  test "a session gives back what it holds however it stops", %{tmp_dir: dir} = context do
    for action <- [:complete, :cancel, :owner_down, :encode_error] do
      chunks = if action == :encode_error, do: failing_chunks(), else: chunks()
      spool_path = Path.join(dir, "#{action}.tmp")
      {owner, coordinator} = start_owned(context, chunks, spool_path)
      ref = Process.monitor(coordinator)
      assert_receive {:processing_stopped, _result}

      unless action == :encode_error do
        assert Budget.held(:memory) > elem(context.held, 0)
        assert Budget.held(:spool) > elem(context.held, 1)
      end

      case action do
        :complete -> drain(coordinator)
        :cancel -> assert Coordinator.cancel(coordinator) == :ok
        :owner_down -> Task.shutdown(owner, :brutal_kill)
        :encode_error -> assert {:error, _reason} = drain(coordinator)
      end

      assert_receive {:DOWN, ^ref, :process, ^coordinator, _reason}
      assert {Budget.held(:memory), Budget.held(:spool)} == context.held
    end
  end

  @tag :tmp_dir
  test "past the memory limit, a session spools what it can't send", %{tmp_dir: dir} = context do
    hold(:memory, Budget.limit(:memory))
    chunks = ["one", :binary.copy("a", @mb)]
    {_owner, coordinator} = start_owned(context, chunks, Path.join(dir, "spool.tmp"))
    assert_receive {:processing_stopped, :ok}
    assert Budget.held(:memory) == elem(context.held, 0) + Budget.limit(:memory)
    assert Budget.held(:spool) == elem(context.held, 1) + @mb
    assert drain(coordinator) == :binary.copy("a", @mb)
  end

  @tag :tmp_dir
  test "past both limits, a session keeps pace with its client", %{tmp_dir: dir} = context do
    hold(:memory, Budget.limit(:memory))
    hold(:spool, Budget.limit(:spool))
    test = self()

    chunks =
      Stream.map(1..12, fn index ->
        send(test, {:pulled, index})
        chunk(index)
      end)

    {_owner, coordinator} = start_owned(context, chunks, Path.join(dir, "spool.tmp"))

    # With no room in the VM, the encode waits after the first chunk.
    assert_receive {:pulled, 1}
    _state = :sys.get_state(coordinator)
    refute_received {:pulled, 2}
    assert Budget.held(:spool) == elem(context.held, 1) + Budget.limit(:spool)
    assert %{active: 1} = ProcessingPool.stats(context.pool)

    assert drain(coordinator) == IO.iodata_to_binary(Enum.map(2..12, &chunk/1))
    assert_receive {:processing_stopped, :ok}
  end

  # Starts a session owned by a task that waits, and returns both.
  defp start_owned(context, chunks, spool_path) do
    test = self()

    owner =
      Task.Supervisor.async_nolink(context.tasks, fn ->
        build = fn pump -> pump.(chunks, "image/png", resolved(), nil) end
        session = [spool_path: spool_path]

        {:ok, coordinator} =
          Coordinator.start(build, self(), nil, session, RequestContext.capture(), context.config)

        {:ok, _prepared} = Coordinator.prepare(coordinator)
        send(test, {:started, coordinator})
        receive do: (:finish -> :ok)
      end)

    assert_receive {:started, coordinator}
    {owner, coordinator}
  end

  defp drain(coordinator, acc \\ []) do
    case Coordinator.next(coordinator) do
      {:chunk, chunk} -> drain(coordinator, [acc, chunk])
      :done -> IO.iodata_to_binary(acc)
      {:error, _reason} = error -> error
    end
  end

  # Holds `bytes` of `kind` as another session would, until the test ends.
  defp hold(kind, bytes) do
    Budget.add(kind, bytes)
    on_exit(fn -> Budget.add(kind, -bytes) end)
  end

  # 12 MB, made as the encode pulls it.
  defp chunks, do: Stream.map(1..12, &chunk/1)

  # Fails after 8 MB, past the memory window.
  defp failing_chunks do
    Stream.map(1..12, fn
      9 -> raise "encode failure"
      index -> chunk(index)
    end)
  end

  defp chunk(index), do: :binary.copy(<<index>>, @mb)

  defp resolved do
    %Resolved{
      format: :png,
      quality: :default,
      response_headers: [],
      strip_metadata: true,
      keep_copyright: true,
      color_profile: :strip
    }
  end
end
