defmodule ImagePipe.Telemetry.Trace.TestReqAdapter do
  @moduledoc false

  def run(request) do
    respond = Req.Request.get_private(request, :test_response)
    respond.(request)
  end
end
