defmodule ImagePipe.Delivery.CoordinatorTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Telemetry.RequestContext

  test "status diagnostics leave out the configuration and its credentials" do
    secret = "fake-origin-secret"
    config = [sources: [origin: [options: [req_options: [headers: [{"x-api-key", secret}]]]]]]
    build_fun = fn _pump -> :ok end

    {:ok, pid} =
      Coordinator.start(build_fun, self(), nil, [], RequestContext.capture(), config)

    refute inspect(:sys.get_status(pid), limit: :infinity) =~ secret
    GenServer.stop(pid)
  end
end
