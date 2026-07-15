defmodule ImagePipe.Test.Delivery.SessionProbe do
  @moduledoc """
  Finds the `ImagePipe.Delivery.Coordinator`s owned by the calling process, so
  a test can observe session liveness and teardown for itself.

  `ImagePipe.Delivery.stream/5` requires `self()` as the conn owner, and the
  coordinator `Process.monitor/1`s that owner in `init/1`. So a live session is
  always visible to its owner through `:monitored_by`, identified by the
  `$initial_call` `:proc_lib` records for it — no cooperation from production
  code is needed, and in particular the primitive does not have to leave a
  monitor of its own behind for tests to key off.
  """

  # Test-only helper that names a non-exported Delivery internal to identify
  # the coordinator; opt out of Boundary's outgoing checks rather than widen
  # the ImagePipe.Delivery export surface for a test affordance.
  use Boundary, top_level?: true, check: [out: false]

  @coordinator ImagePipe.Delivery.Coordinator

  @doc """
  The live delivery coordinators owned by the calling process.
  """
  @spec coordinators() :: [pid()]
  def coordinators do
    {:monitored_by, pids} = Process.info(self(), :monitored_by)
    Enum.filter(pids, &coordinator?/1)
  end

  defp coordinator?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        Keyword.get(dictionary, :"$initial_call") == {@coordinator, :init, 1}

      nil ->
        false
    end
  end
end
