defmodule ImagePipe.Request.VixStreamContinuationTest do
  use ExUnit.Case, async: false

  alias ImagePipe.Output.Policy
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path
  alias ImagePipe.Request.SourceSession.Producer
  alias ImagePipe.Request.SourceSession.Request
  alias ImagePipe.Source.Resolved, as: ResolvedSource
  alias ImagePipe.SourceTest.ValidAdapter
  alias ImagePipe.Test.SourceSession.ProducerClient

  @cleanup_observation_timeout 1_000

  defmodule ProofServer do
    use GenServer

    @call_timeout 5_000

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts)
    end

    def next(pid) do
      GenServer.call(pid, :next, @call_timeout)
    end

    def debug_state(pid) do
      GenServer.call(pid, :debug_state, @call_timeout)
    end

    def cancel(pid) do
      GenServer.call(pid, :cancel, @call_timeout)
    end

    def helper_snapshot(pid) do
      GenServer.call(pid, :helper_snapshot, @call_timeout)
    end

    @impl GenServer
    def init(opts) do
      Process.flag(:trap_exit, true)

      {:links, links} = Process.info(self(), :links)

      {:ok,
       %{
         initial_links: MapSet.new(links),
         image: Keyword.fetch!(opts, :image),
         suffix: Keyword.get(opts, :suffix, ".jpg"),
         write_options: Keyword.get(opts, :write_options, []),
         stream: nil,
         suspended: nil,
         target_pipe: nil,
         target_task: nil,
         exits: []
       }}
    end

    @impl GenServer
    def handle_call(:next, _from, state) do
      {reply, state} = safe_next_chunk(state)
      {:reply, reply, state}
    end

    @impl GenServer
    def handle_call(:debug_state, _from, state) do
      debug_state = Map.take(state, [:suspended, :exits])
      {:reply, debug_state, state}
    end

    @impl GenServer
    def handle_call(:cancel, _from, state) do
      state = halt_stream(state)
      {:reply, :ok, state}
    end

    @impl GenServer
    def handle_call(:helper_snapshot, _from, state) do
      {:reply, build_helper_snapshot(state), state}
    end

    @impl GenServer
    def handle_info({:EXIT, pid, :shutdown}, state) do
      # Initial links are test/supervisor ownership links, not Vix helper links.
      # Their shutdown is controlled test cleanup.
      if MapSet.member?(state.initial_links, pid) do
        {:stop, :shutdown, halt_stream(state)}
      else
        {:noreply, %{state | exits: [{pid, :shutdown} | state.exits]}}
      end
    end

    @impl GenServer
    def handle_info({:EXIT, pid, reason}, state) do
      {:noreply, %{state | exits: [{pid, reason} | state.exits]}}
    end

    defp safe_next_chunk(state) do
      next_chunk(state)
    rescue
      exception ->
        {{:error, exception}, state |> safe_halt_stream() |> stop_observed_target_pipe()}
    catch
      kind, reason ->
        {{:error, {kind, reason}}, state |> safe_halt_stream() |> stop_observed_target_pipe()}
    end

    defp next_chunk(%{stream: nil} = state) do
      before_links = linked_processes()

      stream =
        Image.stream!(
          state.image,
          Keyword.merge([suffix: state.suffix, buffer_size: 0], state.write_options)
        )

      state
      |> Map.put(:stream, stream)
      |> reduce_and_capture_target_pipe(before_links)
    end

    defp next_chunk(%{suspended: nil} = state), do: {:done, state}

    defp next_chunk(%{suspended: {acc, continuation}} = state) do
      continuation.({:cont, acc})
      |> handle_reduce_result(%{state | suspended: nil})
    end

    defp reduce_and_capture_target_pipe(state, before_links) do
      result = reduce_for_one_chunk(state.stream)

      handle_reduce_result(result, capture_target_pipe(state, before_links))
    rescue
      exception ->
        state = capture_target_pipe(state, before_links)
        {{:error, exception}, stop_observed_target_pipe(state)}
    catch
      kind, reason ->
        state = capture_target_pipe(state, before_links)
        {{:error, {kind, reason}}, stop_observed_target_pipe(state)}
    end

    defp reduce_for_one_chunk(stream) do
      Enumerable.reduce(stream, {:cont, nil}, fn chunk, _acc ->
        {:suspend, chunk}
      end)
    end

    defp handle_reduce_result({:suspended, chunk, continuation}, state)
         when is_binary(chunk) do
      {{:chunk, chunk}, %{state | suspended: {chunk, continuation}}}
    end

    defp handle_reduce_result({:done, _acc}, state), do: {:done, %{state | suspended: nil}}
    defp handle_reduce_result({:halted, _acc}, state), do: {:done, %{state | suspended: nil}}

    defp halt_stream(%{suspended: nil} = state), do: state

    defp halt_stream(%{suspended: {acc, continuation}} = state) do
      _result = continuation.({:halt, acc})
      %{state | suspended: nil}
    end

    defp safe_halt_stream(state) do
      halt_stream(state)
    catch
      :exit, _reason -> %{state | suspended: nil}
    end

    defp stop_observed_target_pipe(%{target_pipe: nil} = state), do: state

    defp stop_observed_target_pipe(%{target_pipe: pipe} = state) do
      try do
        Vix.TargetPipe.stop(pipe)
      catch
        :exit, _reason -> :ok
      end

      state
    end

    defp capture_target_pipe(state, before_links) do
      linked_processes()
      |> MapSet.difference(before_links)
      |> Enum.find(fn pid -> process_module(pid) == Vix.TargetPipe end)
      |> attach_target_pipe(state)
    end

    defp attach_target_pipe(nil, state), do: state

    defp attach_target_pipe(pid, state) do
      %{state | target_pipe: pid, target_task: target_task(pid)}
    end

    defp build_helper_snapshot(state) do
      %{
        target_pipe: state.target_pipe,
        target_task: state.target_task,
        exits: Enum.reverse(state.exits),
        linked_processes: MapSet.to_list(linked_processes()),
        linked_process_diagnostics: linked_process_diagnostics()
      }
    end

    defp target_task(pid) when is_pid(pid) do
      case :sys.get_state(pid) do
        %{task_pid: task_pid} when is_pid(task_pid) -> task_pid
        _state -> nil
      end
    catch
      :exit, _reason -> nil
    end

    defp linked_processes do
      {:links, links} = Process.info(self(), :links)
      MapSet.new(links)
    end

    defp process_module(pid) when is_pid(pid) do
      case :sys.get_state(pid) do
        %{__struct__: module} -> module
        _state -> nil
      end
    catch
      :exit, _reason -> nil
    end

    defp linked_process_diagnostics do
      Enum.map(linked_processes(), fn pid ->
        %{
          pid: pid,
          current_function: Process.info(pid, :current_function),
          initial_call: Process.info(pid, :initial_call),
          registered_name: Process.info(pid, :registered_name),
          state: safe_sys_state(pid)
        }
      end)
    end

    defp safe_sys_state(pid) do
      :sys.get_state(pid)
    catch
      :exit, reason -> {:exit, reason}
    end
  end

  @tag :full_stream
  test "collects a complete encoded stream through repeated calls" do
    image = Image.open!("priv/static/images/beach.jpg")
    pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

    {body, chunk_count} = collect_chunks_with_count(pid, [], 0)

    assert chunk_count >= 1

    assert {:ok, decoded} =
             Image.open(IO.iodata_to_binary(body), access: :random, fail_on: :error)

    assert Image.width(decoded) > 0
    assert Image.height(decoded) > 0
  end

  @tag :suspension
  test "stores the real suspended reducer state between calls" do
    image = Image.open!("priv/static/images/beach.jpg")
    pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

    assert {:chunk, first_chunk} = ProofServer.next(pid)
    assert is_binary(first_chunk)

    state_after_first_chunk = ProofServer.debug_state(pid)

    # The accumulator shape is test-owned. The proof is that the real continuation
    # returned by Enumerable.reduce/3 can be stored and resumed later.
    assert {^first_chunk, continuation} = state_after_first_chunk.suspended
    assert is_function(continuation, 1)

    case ProofServer.next(pid) do
      :done -> :ok
      {:chunk, second_chunk} -> assert is_binary(second_chunk)
    end

    state_after_resume = ProofServer.debug_state(pid)

    assert state_after_resume.suspended == nil or
             match?(
               {_acc, continuation} when is_function(continuation, 1),
               state_after_resume.suspended
             )
  end

  @tag :cancel_cleanup
  @tag :writer_cleanup
  test "cancel halts the continuation and stops the observed writer task" do
    image = Image.new!(4_000, 4_000, color: [120, 40, 20], bands: 3)
    pid = start_supervised!({ProofServer, image: image, suffix: ".jpg"})

    assert {:chunk, chunk} = ProofServer.next(pid)
    assert is_binary(chunk)

    snapshot = ProofServer.helper_snapshot(pid)

    assert is_pid(snapshot.target_pipe),
           "target pipe was not observed:\n#{linked_process_diagnostics(snapshot)}"

    :ok = ProofServer.cancel(pid)
    assert ProofServer.next(pid) == :done

    assert {:down, _reason} = assert_process_down(snapshot.target_pipe)

    writer_cleanup_result =
      case assert_process_down(snapshot.target_task) do
        {:alive, writer_pid} ->
          cleanup_process(writer_pid)
          {:failed, :writer_alive}

        :not_observed ->
          {:inconclusive, :writer_not_observed}

        {:down, _reason} ->
          :passed
      end

    assert writer_cleanup_result == :passed,
           "expected observed writer task to exit after cancel, got #{inspect(writer_cleanup_result)}:\n#{linked_process_diagnostics(snapshot)}"
  end

  @tag :producer_cleanup
  @tag :writer_cleanup
  test "killing a source session producer stops the observed target pipe" do
    Process.flag(:trap_exit, true)

    producer = start_producer(producer_request())
    ref = Process.monitor(producer)

    assert {:ok, {:first_chunk, first_chunk, "image/jpeg", [], _resolved_output, _debug}} =
             ProducerClient.next(producer)

    assert is_binary(first_chunk)

    snapshot = producer_helper_snapshot(producer)

    assert is_pid(snapshot.target_pipe),
           "target pipe was not observed:\n#{linked_process_diagnostics(snapshot)}"

    Process.exit(producer, :shutdown)
    assert_receive {:DOWN, ^ref, :process, ^producer, :shutdown}

    assert {:down, _reason} = assert_process_down(snapshot.target_pipe)

    writer_cleanup_result =
      case assert_process_down(snapshot.target_task) do
        {:alive, writer_pid} ->
          cleanup_process(writer_pid)
          {:failed, :writer_alive}

        :not_observed ->
          {:inconclusive, :writer_not_observed}

        {:down, _reason} ->
          :passed
      end

    assert writer_cleanup_result == :passed,
           "expected observed writer task to exit after producer shutdown, got #{inspect(writer_cleanup_result)}:\n#{linked_process_diagnostics(snapshot)}"
  end

  defp cleanup_process(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @cleanup_observation_timeout ->
        Process.demonitor(ref, [:flush])
        flunk("could not clean up observed writer task: #{inspect(pid)}")
    end
  end

  defp linked_process_diagnostics(snapshot) do
    inspect(snapshot.linked_process_diagnostics, pretty: true, limit: 20, printable_limit: 1_000)
  end

  defp producer_helper_snapshot(producer) do
    linked_processes = producer_linked_processes(producer)
    target_pipe = Enum.find(linked_processes, fn pid -> process_module(pid) == Vix.TargetPipe end)

    %{
      target_pipe: target_pipe,
      target_task: target_task(target_pipe),
      linked_process_diagnostics: inspect_linked_processes(linked_processes)
    }
  end

  defp producer_linked_processes(producer) do
    case Process.info(producer, :links) do
      {:links, links} -> links
      nil -> []
    end
  end

  defp start_producer(%Request{} = request) do
    caller_chain = [self()]

    start_supervised!(%{
      id: {Producer, make_ref()},
      start: {Producer, :start_link, [request, [caller_chain: caller_chain]]},
      restart: :temporary,
      shutdown: 2_000,
      type: :worker
    })
  end

  defp target_task(nil), do: nil

  defp target_task(pid) when is_pid(pid) do
    case :sys.get_state(pid) do
      %{task_pid: task_pid} when is_pid(task_pid) -> task_pid
      _state -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp process_module(pid) when is_pid(pid) do
    case :sys.get_state(pid) do
      %{__struct__: module} -> module
      _state -> nil
    end
  catch
    :exit, _reason -> nil
  end

  defp inspect_linked_processes(linked_processes) do
    Enum.map(linked_processes, fn pid ->
      %{
        pid: pid,
        current_function: Process.info(pid, :current_function),
        initial_call: Process.info(pid, :initial_call),
        registered_name: Process.info(pid, :registered_name),
        state: safe_sys_state(pid)
      }
    end)
  end

  defp safe_sys_state(pid) do
    :sys.get_state(pid)
  catch
    :exit, reason -> {:exit, reason}
  end

  defp collect_chunks_with_count(pid, chunks, count) do
    case ProofServer.next(pid) do
      {:chunk, chunk} -> collect_chunks_with_count(pid, [chunk | chunks], count + 1)
      :done -> {Enum.reverse(chunks), count}
    end
  end

  defp producer_request do
    runtime_opts = [
      sources: %{path: {ValidAdapter, []}},
      output_formats: [jpeg: []],
      output_negotiation: [],
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000,
      max_result_width: 8_192,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    ]

    %Request{
      plan: plan(),
      resolved_source: resolved_source(),
      output_policy:
        Policy.from_output_plan(
          Plug.Test.conn(:get, "/"),
          %Output{mode: {:explicit, :jpeg}},
          runtime_opts
        ),
      opts: runtime_opts,
      cache_key: nil
    }
  end

  defp plan do
    %Plan{
      source: %Path{segments: ["images", "beach.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: %Output{mode: {:explicit, :jpeg}}
    }
  end

  defp resolved_source do
    %ResolvedSource{
      adapter: :path,
      source_kind: :path,
      identity: [kind: :path, root: "test", path: ["images", "beach.jpg"]],
      fetch: :fixture,
      internal_cache: :enabled,
      http_cache: :inherit,
      cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false}
    }
  end

  defp assert_process_down(nil), do: :not_observed

  defp assert_process_down(pid) when is_pid(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:down, reason}
    after
      @cleanup_observation_timeout ->
        Process.demonitor(ref, [:flush])
        {:alive, pid}
    end
  end
end
