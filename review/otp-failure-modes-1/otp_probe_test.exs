defmodule OtpProbe.RaisingDetector do
  @behaviour ImagePipe.Transform.Detector
  def supported_classes(_opts), do: ["face"]
  def detect(_image, _opts), do: {:ok, []}
  def available?(_opts), do: true
  def identity(_opts), do: {__MODULE__, :v1}

  def warmup(_opts) do
    if pid = Process.whereis(OtpProbe.RaisingDetector), do: send(pid, :warmup_attempt)
    raise "model server unreachable"
  end
end

defmodule OtpProbe.Test do
  use ExUnit.Case, async: false
  import Plug.Test

  alias ImagePipe.Cache
  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.Cache.FileSystem.Writers
  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery
  alias ImagePipe.Output.Resolved
  alias ImagePipe.ProcessingPool
  alias ImagePipe.Test.Caches

  setup do
    root = Path.join(System.tmp_dir!(), "otp_probe_#{System.unique_integer([:positive])}")
    images = Path.join(root, "images")
    File.mkdir_p!(images)
    Image.new!(24, 16, color: :red) |> Image.write!(Path.join(images, "red.png"))
    on_exit(fn -> File.rm_rf!(root) end)

    sources = [
      media: [adapter: ImagePipe.Source.File, match: :path, options: [root: images, root_id: "m"]]
    ]

    %{root: Path.join(root, "cache"), sources: sources}
  end

  defp summ(%Plug.Conn{status: s, resp_body: b}), do: {s, b}
  defp summ(other), do: other

  defp cache_sup(root) do
    [cache] =
      for {:cache, pid, :supervisor, _} <- Supervisor.which_children(FileSystem.Root.name(root: root)),
          do: pid

    cache
  end

  defp admission(root) do
    case Registry.lookup(FileSystem.registry_name(root), root) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp wait_until(fun, n \\ 200) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("timed out")
      true -> receive(after: (10 -> wait_until(fun, n - 1)))
    end
  end

  test "T1: after Admission restarts, the cache's periodic sweep is gone", ctx do
    Caches.start!(sources: ctx.sources, cache: [root: ctx.root])
    before = Supervisor.which_children(cache_sup(ctx.root)) |> Enum.map(&elem(&1, 0))
    IO.inspect(before, label: "T1 cache children before")
    old = admission(ctx.root)
    Process.exit(old, :kill)
    wait_until(fn -> (pid = admission(ctx.root)) && pid != old end)
    later = Supervisor.which_children(cache_sup(ctx.root)) |> Enum.map(&elem(&1, 0))
    IO.inspect(later, label: "T1 cache children after Admission restart")
  end

  test "T2: a detector whose warmup raises takes the whole instance down", ctx do
    Process.register(self(), OtpProbe.RaisingDetector)
    name = Module.concat(__MODULE__, "T2#{System.unique_integer([:positive])}")
    t0 = System.monotonic_time(:millisecond)

    pid =
      start_supervised!(
        {ImagePipe, name: name, sources: ctx.sources, cache: [root: ctx.root, max_size_bytes: 1_000_000],
         detector: OtpProbe.RaisingDetector}
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason}, 5_000
    IO.inspect({reason, System.monotonic_time(:millisecond) - t0}, label: "T2 instance down (reason, ms)")
    attempts = Stream.repeatedly(fn -> receive(do: (:warmup_attempt -> 1), after: (0 -> nil)) end) |> Enum.take_while(& &1) |> length()
    IO.inspect(attempts, label: "T2 warmup attempts")

    result =
      try do
        ImagePipe.Plug.call(conn(:get, "/w=8/format=png/src/red.png"), ImagePipe.Plug.init(instance: name))
      rescue
        e -> {:raised, e.__struct__, Exception.message(e)}
      end

    IO.inspect(summ(result), label: "T2 request while instance is down")
    for _ <- 1..3 do
      r = try do
        ImagePipe.Plug.call(conn(:get, "/w=8/format=png/src/red.png"), ImagePipe.Plug.init(instance: name))
      rescue
        e -> {:raised, e.__struct__, Exception.message(e)}
      end
      IO.inspect(summ(r), label: "T2 again")
    end
  end

  test "T3: a writer stopped by its supervisor skips the drain the code intends", ctx do
    opts = Cache.validate_config!(Caches.start!(cache: [root: ctx.root]))
    key = fn seed -> %Key{hash: :crypto.hash(:sha256, seed) |> Base.encode16(case: :lower), data: []} end

    for {label, stopper} <- [
          {"exit from a non-parent (as writer_test does)", fn w -> Process.exit(w, :shutdown) end},
          {"exit from the Writers supervisor (a real shutdown)",
           fn w ->
             sup = Process.info(w, :dictionary) |> elem(1) |> Keyword.get(:"$ancestors") |> hd()
             spawn(fn -> DynamicSupervisor.terminate_child(sup, w) end)
             receive(after: (50 -> :ok))
           end}
        ] do
      k = key.(label)
      sink = Cache.open_sink(k, {:complete_body, "text/plain"}, [], opts)
      w = sink.writer
      wait_until(fn -> :sys.get_state(w).store != nil end)
      ref = Process.monitor(w)
      # Keep the writer busy (not suspended: a suspended process handles its
      # parent's exit at once) while the exit, the chunk and the commit queue.
      spawn(fn -> :sys.replace_state(w, fn s -> Process.sleep(300); s end) end)
      receive(after: (20 -> :ok))
      stopper.(w)
      wait_until(fn -> {:message_queue_len, n} = Process.info(w, :message_queue_len); n >= 1 end)
      sink = Cache.write_chunk(sink, "body", opts)
      :ok = Cache.commit_sink(sink, opts)
      assert_receive {:DOWN, ^ref, :process, _, reason}, 5_000
      Caches.await_writes(opts)
      stored = Cache.lookup_entry(k, opts) |> elem(0)
      IO.inspect({reason, stored}, label: "T3 #{label}: (exit reason, entry stored?)")
    end
  end

  test "T4: a producer whose coordinator is killed holds its slot past every deadline" do
    pool = start_supervised!({ProcessingPool, max_concurrency: 1, max_queue: 0, processing_timeout: 300, queue_timeout: 100})
    config = [processing_pool: pool]

    resolved = %Resolved{format: :jpeg, quality: :default, response_headers: [], strip_metadata: true, keep_copyright: true, color_profile: :strip}
    build = fn pump -> pump.(["one", "two"], "image/jpeg", resolved, nil) end
    assert {:ok, stream} = Delivery.stream(build, nil, config)
    %{active: 1} = ProcessingPool.stats(pool)
    # The coordinator is the process the stream's closures call.
    {:env, [coord | _]} = Function.info(stream.next, :env)
    Process.exit(coord, :kill)
    receive(after: (1_000 -> :ok))
    IO.inspect(ProcessingPool.stats(pool), label: "T4 pool 1 s after the coordinator died (deadline 300 ms)")
    IO.inspect(ProcessingPool.run(pool, fn -> :ran end, []), label: "T4 next request")
  end
end
