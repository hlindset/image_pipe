defmodule ImagePipe.Telemetry.Trace.TestReqAdapter do
  @moduledoc false
  @behaviour Req.Adapter

  @impl true
  def stream(request, acc, fun, state) do
    respond = Req.Request.get_private(request, :test_response)

    case respond.(request) do
      {request, %Req.Response{} = response} ->
        response = %{response | request: request}

        with {:ok, response, acc, state} <-
               fun.({:status, response.status}, response, acc, state),
             {:ok, response, acc, state} <-
               fun.({:headers, Req.get_headers_list(response)}, response, acc, state) do
          fun.({:data, response.body}, response, acc, state)
        end

      {request, %{__exception__: true} = exception} ->
        {{:error, exception}, Req.Response.new(request: request), acc, state}
    end
  end
end
