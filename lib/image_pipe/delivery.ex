defmodule ImagePipe.Delivery do
  @moduledoc """
  Streaming delivery sessions for the request runner's image terminal.

  ## Process ownership

    * **conn owner** — the process running the ImagePipe plug request
      (`self()` when calling `stream/5`). It holds the prepared stream's
      `next`/`cancel` closures.
    * **coordinator** (`Delivery.Coordinator`) — monitors the owner and owns
      the cache sink. On owner `:DOWN`, it requests a graceful producer halt
      and aborts the sink. The monitor must point from coordinator to owner
      to detect owner death.
    * **producer** (`Delivery.Producer`) — linked to and monitored by the
      coordinator. It runs `build_fun`'s fetch → decode → transform → encode
      flow and the `pump` demand loop. Only encoded chunks cross the process
      boundary; the lazy vips image and encoder enumerable stay here.

  `build_fun` must remain inside its resource brackets until `pump` reaches
  EOF or halts. Cleanup runs once inside the producer on completion, owner
  disconnect, and explicit cancellation.

  ## Graceful cancellation

  Owner death and explicit cancellation send `{:halt, ...}` so the producer
  can finish its current work and run `after` cleanup. The producer does not
  trap exits, so a shutdown signal would skip that cleanup. A short timeout
  force-kills a stuck producer; cleanup may not run in that case.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Plan,
      ImagePipe.ProcessingPool,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    # The runner uses first_chunk/1 and resume/2 to keep the first pull inside
    # its encode span, then hand the chunk to pump.
    exports: [StreamPull]

  alias ImagePipe.Cache.Key
  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Response.PreparedStream
  alias ImagePipe.Telemetry.Trace

  @type build_fun :: ImagePipe.Delivery.Producer.build_fun()

  @doc """
  Starts a delivery session, drives it through its first demand, and returns
  a `%ImagePipe.Response.PreparedStream{}` once the first encoded chunk is
  ready.

  `conn_owner_pid` must be `self()`, the process running the plug request.
  The coordinator monitors it for owner death. Both coordinator and producer
  inherit the calling process's current trace context.

  `cache_key` is `nil` when the request runner has no cache configured for
  this request; the session then simply stages nothing.

  `build_fun` runs fetch → decode → transform → encode in the producer, keeping
  `pump` inside its resource brackets as described above. It passes encoder
  output and collected `ImagePipe.Debug.Info` (or `nil`) to `pump`. The session
  includes this debug data in the prepared stream and staged cache entry,
  adding measured generation cost as the `:total` timing.
  """
  @spec stream(pid(), build_fun(), Key.t() | nil, PlanResponse.t(), keyword()) ::
          {:ok, PreparedStream.t()} | {:error, term()}
  def stream(conn_owner_pid, build_fun, cache_key, %PlanResponse{} = response_meta, config)
      when is_pid(conn_owner_pid) and is_function(build_fun, 1) and is_list(config) do
    {:ok, coordinator} =
      Coordinator.start(build_fun, conn_owner_pid, cache_key, Trace.Stack.context(), config)

    case Coordinator.prepare(coordinator) do
      {:ok, prepared} -> prepared_stream(coordinator, cache_key, response_meta, prepared)
      {:error, reason} -> cancel_and_error(coordinator, reason)
    end
  end

  defp prepared_stream(coordinator, cache_key, response_meta, prepared) do
    case PlanResponse.content_disposition(response_meta, prepared.content_type) do
      {:ok, content_disposition} ->
        {:ok,
         %PreparedStream{
           first_chunk: prepared.first_chunk,
           content_type: prepared.content_type,
           headers:
             prepared.resolved_output.response_headers ++
               [{"content-disposition", content_disposition}],
           next: fn -> Coordinator.next(coordinator) end,
           cancel: fn -> Coordinator.cancel(coordinator) end,
           resolved_output: prepared.resolved_output,
           debug: prepared.debug,
           cache_key: key_hash(cache_key)
         }}

      {:error, reason} ->
        cancel_and_error(coordinator, reason)
    end
  end

  # Cancel on every error; this is a no-op if the session already stopped.
  # A session timeout can leave the coordinator and producer alive. Under
  # Bandit, waiting for owner death would retain them for the keep-alive
  # connection's lifetime.
  defp cancel_and_error(coordinator, reason) do
    _cancel_result = Coordinator.cancel(coordinator)
    {:error, reason}
  end

  defp key_hash(%Key{hash: hash}), do: hash
  defp key_hash(nil), do: nil
end
