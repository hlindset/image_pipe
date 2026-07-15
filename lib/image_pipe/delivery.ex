defmodule ImagePipe.Delivery do
  @moduledoc """
  Dialect-owned streaming delivery session for a dialect's image terminal —
  a simplified, monitor-based analog of
  `ImagePipe.Request.SourceSession`/`Producer` [pipelines §Design principles
  1, streaming corner case].

  ## Process topology (the flagged invariant)

  Three processes, three distinct ownership roles:

    * **conn owner** — the process running the calling dialect's `Plug.call/2`
      (`self()` at the point `stream/5` is called, always). It holds the
      `%ImagePipe.Response.PreparedStream{}` `next`/`cancel` closures and
      monitors the coordinator for teardown visibility.
    * **coordinator** (`Delivery.Coordinator`) — `Process.monitor(owner)` in
      its own `init/1`. THIS is the monitor direction that matters: a plain
      `spawn_monitor` from the owner would only ever observe the coordinator
      dying, never the reverse. Owner-death detection requires the
      coordinator to watch the owner, mirroring
      `ImagePipe.Request.SourceSession.init/1` (`source_session.ex:84`,
      `Process.monitor(owner)`). The coordinator owns the cache sink and,
      on owner `:DOWN`, requests a graceful producer halt and aborts the
      sink.
    * **producer** (`Delivery.Producer`) — linked AND monitored by the
      coordinator (mirrors `SourceSession`'s own producer exactly). It stays
      *inside* the fetch/decode brackets for its entire lifetime: `build_fun`
      (constructed by the calling dialect) enters
      `ImagePipe.Decode.with_image/4` (which itself enters
      `ImagePipe.Source.with_fetched/3`) and, from INSIDE that nested
      callback, calls the `pump` function this module hands it. `pump` runs
      the entire chunk-demand loop — only encoded chunks cross the process
      boundary (via plain messages); the lazy vips image and the encoder
      `Enumerable` never leave the producer process, and never leave the
      bracket: `build_fun` does not return until the encoder reaches EOF or
      is halted, so the bracket's own cleanup (a `try/after` around the
      pipeline+encode+pump body, owned by the calling dialect) always runs
      exactly once, whether by normal completion, an owner disconnect, or an
      explicit `cancel`.

  ## Why owner-down uses a graceful halt, not a forceful kill

  `SourceSession` force-kills its producer on owner-down
  (`Process.exit(producer, :shutdown)` — the producer never traps exits, so
  the exit signal terminates it immediately, with no further Elixir code
  running). This coordinator does not do that: because the calling dialect's
  producer runs a `try/after` around its own encode/pump body (the bracket-
  cleanup instrumentation), a forceful kill would skip that `after` block.
  Instead, owner-down (like an explicit `cancel/1`) sends a graceful
  `{:halt, ...}` message and lets the producer finish its current unit of
  work, hit `after`, and reply — backstopped by a short timeout that force-
  kills a genuinely wedged producer (accepting, in that narrow edge case,
  that cleanup may not run).
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      ImagePipe.Output,
      ImagePipe.Plan,
      ImagePipe.Representation,
      ImagePipe.Response,
      ImagePipe.Telemetry
    ],
    exports: []

  alias ImagePipe.Delivery.Coordinator
  alias ImagePipe.Plan.Response, as: PlanResponse
  alias ImagePipe.Representation
  alias ImagePipe.Response.PreparedStream

  @type build_fun :: ImagePipe.Delivery.Producer.build_fun()

  @doc """
  Starts a delivery session, drives it through its first demand, and returns
  a `%ImagePipe.Response.PreparedStream{}` once the first encoded chunk is
  ready — mirroring `ImagePipe.Request.SourceSession.prepare/2`'s contract,
  minus the supervisor.

  `conn_owner_pid` MUST be `self()` at the call site (the process running
  the calling dialect's `Plug.call/2`) — the coordinator's owner-death
  detection is keyed off this pid.

  `build_fun` runs fetch → decode → transform → encode entirely inside the
  producer process; see the moduledoc for the bracket-containment contract
  it must uphold.
  """
  @spec stream(pid(), build_fun(), Representation.t(), PlanResponse.t(), keyword()) ::
          {:ok, PreparedStream.t()} | {:error, term()}
  def stream(
        conn_owner_pid,
        build_fun,
        %Representation{} = representation,
        %PlanResponse{} = response_meta,
        config
      )
      when is_pid(conn_owner_pid) and is_function(build_fun, 1) and is_list(config) do
    {:ok, coordinator} =
      Coordinator.start(build_fun, conn_owner_pid, representation.cache_key, config)

    _owner_teardown_monitor = Process.monitor(coordinator)

    case Coordinator.prepare(coordinator) do
      {:ok, prepared} -> prepared_stream(coordinator, representation, response_meta, prepared)
      {:error, reason} -> {:error, reason}
    end
  end

  defp prepared_stream(coordinator, %Representation{} = representation, response_meta, prepared) do
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
           cache_key: representation.cache_key.hash
         }}

      {:error, reason} ->
        _cancel_result = Coordinator.cancel(coordinator)
        {:error, reason}
    end
  end
end
