defmodule ImagePipe.Delivery do
  @moduledoc """
  Monitor-based streaming delivery session — the single streaming topology
  behind both the framework's request runner and a dialect's image terminal
  [pipelines §Design principles 1, streaming corner case].

  ## Process topology (the flagged invariant)

  Three processes, three distinct ownership roles:

    * **conn owner** — the process running the calling dialect's `Plug.call/2`
      (`self()` at the point `stream/5` is called, always). It holds the
      `%ImagePipe.Response.PreparedStream{}` `next`/`cancel` closures.
    * **coordinator** (`Delivery.Coordinator`) — `Process.monitor(owner)` in
      its own `init/1`. THIS is the monitor direction that matters: a plain
      `spawn_monitor` from the owner would only ever observe the coordinator
      dying, never the reverse. Owner-death detection requires the
      coordinator to watch the owner. The coordinator owns the cache sink
      and, on owner `:DOWN`, requests a graceful producer halt and aborts the
      sink.
    * **producer** (`Delivery.Producer`) — linked AND monitored by the
      coordinator. `build_fun` (constructed by the calling dialect) runs the
      whole fetch → decode → transform → encode flow here and, once it has an
      encoder `Enumerable` ready, calls the `pump` function this module hands
      it. `pump` runs the entire chunk-demand loop — only encoded chunks
      cross the process boundary (via plain messages); the lazy vips image
      and the encoder `Enumerable` never leave the producer process.
      `build_fun` does not return until the encoder reaches EOF or is halted,
      so a dialect that wraps its pump call in brackets (e.g.
      `ImagePipe.Decode.with_image/4`, which itself enters
      `ImagePipe.Source.with_fetched/3`) stays *inside* them for the delivery's
      entire lifetime, and their cleanup runs exactly once — whether by normal
      completion, an owner disconnect, or an explicit `cancel`.

  ## Why owner-down uses a graceful halt, not a forceful kill

  A forceful kill (`Process.exit(producer, :shutdown)` — the producer never
  traps exits, so the signal terminates it immediately, with no further Elixir
  code running) would skip any `try/after` still on the producer's stack.
  Since a calling dialect may run its encode/pump body inside such brackets,
  owner-down (like an explicit `cancel/1`) instead sends a graceful
  `{:halt, ...}` message and lets the producer finish its current unit of
  work, hit `after`, and reply — backstopped by a short timeout that force-
  kills a genuinely wedged producer (accepting, in that narrow edge case,
  that cleanup may not run).
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Debug,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry
    ],
    # StreamPull is the encoder-stream demand protocol. It is exported because
    # a calling dialect that forces the first chunk itself (to keep that pull
    # inside its own encode span) needs `first_chunk/1` + `resume/2` to hand
    # the already-pulled chunk back to `pump`.
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

  `conn_owner_pid` MUST be `self()` at the call site (the process running
  the calling dialect's `Plug.call/2`). Two things are keyed off that: the
  coordinator's owner-death detection, and the trace context this function
  captures — the calling process's current span is the parent both hops
  (coordinator and producer) adopt, so a dialect never passes, and can never
  forget to pass, a trace context.

  `cache_key` is `nil` when the calling dialect has no cache configured for
  this request; the session then simply stages nothing.

  `build_fun` runs fetch → decode → transform → encode entirely inside the
  producer process; see the moduledoc for the bracket-containment contract
  it must uphold. It hands its encoder output to `pump`, along with the
  `%ImagePipe.Debug.Info{}` it collected while producing it (or `nil` for a
  dialect that collects none) — the session carries that onto both the
  returned `%PreparedStream{}` and the cache entry it stages, stamping the
  measured generation cost into it as the `:total` timing.
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

  # Every error return from this module reclaims the coordinator before it
  # returns. Most failures already stopped it (a producer error stops the
  # session itself), in which case this is a `:noproc` no-op. The one that does
  # not is `{:session, :timeout}`: the call gave up but the coordinator and its
  # wedged producer are still alive, and the conn owner is not a reclaim path —
  # under Bandit it is the *connection* process, so a wedged encode would hold
  # its producer (vips image, fds) for the rest of a keep-alive connection.
  defp cancel_and_error(coordinator, reason) do
    _cancel_result = Coordinator.cancel(coordinator)
    {:error, reason}
  end

  defp key_hash(%Key{hash: hash}), do: hash
  defp key_hash(nil), do: nil
end
