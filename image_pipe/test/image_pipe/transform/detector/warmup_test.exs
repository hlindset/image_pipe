defmodule ImagePipe.Transform.Detector.WarmupTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Transform.Detector.Warmup

  test "rejects invalid startup options before invoking a detector" do
    for invalid <- [
          [unknown: true],
          [detector: "default"],
          [classes: "face"],
          [classes: [:face]],
          [opts: %{test_pid: self()}],
          [retries: 1]
        ] do
      opts =
        Keyword.merge([detector: __MODULE__.SignalDetector, opts: [test_pid: self()]], invalid)

      assert_raise RuntimeError, ~r/ArgumentError/, fn -> start_supervised!({Warmup, opts}) end
      refute_received {:warm_started, _, _}
    end
  end

  defmodule SignalDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_o), do: ["face"]
    @impl true
    def detect(_i, _o), do: {:ok, []}
    @impl true
    def available?(_o), do: true
    @impl true
    def identity(_o), do: {__MODULE__, :v}
    @impl true
    def warmup(opts) do
      pid = Keyword.fetch!(opts, :test_pid)
      send(pid, {:warm_started, self(), Keyword.get(opts, :classes)})

      receive do
        :release -> :ok
      after
        2_000 -> :ok
      end
    end
  end

  defmodule UnavailableDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_o), do: ["face"]
    @impl true
    def detect(_i, _o), do: {:error, :unavailable}
    @impl true
    def available?(_o), do: false
    @impl true
    def identity(_o), do: {__MODULE__, :unavailable}
    @impl true
    def warmup(opts) do
      if pid = Keyword.get(opts, :test_pid), do: send(pid, :warmup_called)
      {:error, {:detector, :unavailable}}
    end
  end

  # Fails until its fifth attempt.
  defmodule FlakyDetector do
    @behaviour ImagePipe.Transform.Detector
    @impl true
    def supported_classes(_o), do: ["face"]
    @impl true
    def detect(_i, _o), do: {:error, :boom}
    @impl true
    def available?(_o), do: true
    @impl true
    def identity(_o), do: {__MODULE__, :flaky}
    @impl true
    def warmup(opts) do
      counter = Keyword.fetch!(opts, :counter)
      :counters.add(counter, 1, 1)
      send(Keyword.fetch!(opts, :test_pid), {:warmup_attempt, self()})
      if :counters.get(counter, 1) >= 5, do: :ok, else: {:error, :boom}
    end
  end

  test "async warmup does not block start and terminates :normal" do
    pid =
      start_supervised!(
        {Warmup, detector: SignalDetector, classes: ["face"], opts: [test_pid: self()]}
      )

    ref = Process.monitor(pid)
    # start_supervised! returned before warmup completed (it's still blocked in receive):
    assert_receive {:warm_started, worker_pid, ["face"]}
    send(worker_pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "unavailable detector skips warmup entirely and terminates :normal" do
    pid =
      start_supervised!(
        {Warmup, detector: UnavailableDetector, classes: ["face"], opts: [test_pid: self()]}
      )

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
    # available?/1 is false, so warmup is never attempted — no retry storm. The
    # worker is dead by the DOWN, so any warmup signal would already be queued.
    refute_received :warmup_called
  end

  test "a failing warmup keeps retrying until it succeeds, then terminates :normal" do
    opts = [test_pid: self(), counter: :counters.new(1, [])]
    pid = start_supervised!({Warmup, detector: FlakyDetector, classes: ["face"], opts: opts})
    ref = Process.monitor(pid)

    # Each retry waits on a backoff timer; send its message to run it now.
    for _failure <- 1..4 do
      assert_receive {:warmup_attempt, ^pid}
      refute_received {:DOWN, ^ref, :process, ^pid, _reason}
      send(pid, :retry)
    end

    assert_receive {:warmup_attempt, ^pid}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "nil detector disables warmup as a clean no-op" do
    pid = start_supervised!({Warmup, detector: nil, classes: ["face"]})

    ref = Process.monitor(pid)
    # The no-op finishes immediately; if it already terminated before we
    # monitored, the monitor reports :noproc. Either way it ended cleanly — a
    # never-raising worker under :transient would have been restarted otherwise.
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
  end

  test "omitted :detector defaults to :default and terminates cleanly" do
    # No requested classes means no models to load, including when the optional
    # detector dependencies are installed.
    pid = start_supervised!({Warmup, classes: []})

    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, reason} when reason in [:normal, :noproc]
  end
end
