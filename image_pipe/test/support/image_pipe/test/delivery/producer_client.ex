defmodule ImagePipe.Test.Delivery.ProducerClient do
  @moduledoc """
  Blocking, synchronous client for `ImagePipe.Delivery.Producer`, used only by
  tests. Production code drives the producer through
  `ImagePipe.Delivery.Coordinator`, which owns the async reply/monitor
  handling; tests want a simple call/response, so that logic lives here, in
  test support.
  """

  # Test-only helper that deliberately drives the non-exported Producer demand
  # protocol; opt out of Boundary's outgoing checks rather than widen the
  # ImagePipe.Delivery export surface for a test affordance.
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Delivery.Producer
  alias ImagePipe.Output.Resolved

  @call_timeout 15_000
  @halt_timeout 2_000

  @spec next(pid(), timeout()) ::
          {:ok,
           {:first_chunk, binary(), String.t(), Resolved.t(), ImagePipe.Debug.Info.t() | nil}}
          | {:ok, {:chunk, binary()}}
          | {:ok, :done}
          | {:error, term()}
  def next(pid, timeout \\ @call_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = Producer.request_next(pid, self())
    receive_reply_or_down(ref, monitor_ref, pid, timeout)
  end

  @spec halt(pid(), timeout()) :: :ok | {:error, term()}
  def halt(pid, timeout \\ @halt_timeout) when is_pid(pid) do
    monitor_ref = Process.monitor(pid)
    ref = Producer.request_halt(pid, self())
    receive_reply_or_down(ref, monitor_ref, pid, timeout)
  end

  defp receive_reply_or_down(ref, monitor_ref, pid, timeout) do
    receive do
      {^ref, reply} ->
        Process.demonitor(monitor_ref, [:flush])
        reply

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        receive do
          {^ref, reply} -> reply
        after
          0 -> {:error, {:producer, {:exit, reason}}}
        end
    after
      timeout ->
        Process.demonitor(monitor_ref, [:flush])

        receive do
          {^ref, _reply} -> :ok
        after
          0 -> :ok
        end

        {:error, {:producer, :timeout}}
    end
  end
end
