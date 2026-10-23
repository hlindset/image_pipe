defmodule ImagePipeServer.Health do
  @moduledoc """
  Liveness and readiness checks, and the flags readiness follows.

  `GET /health/live` answers `200` while the server runs. `GET /health/ready`
  answers `503` until the image listener has started, `200` while serving,
  and `503` again once the server starts draining on shutdown. With an
  `:instance`, it also answers `503` while that `ImagePipe` instance isn't
  running, as while it restarts.
  `ImagePipeServer.Router` serves both on the image listener. As a plug,
  this module serves only them and, with `:stats`, the stats endpoints (see
  `ImagePipeServer.Stats`), on the listener `[server] health_port` starts,
  and answers `404` to anything else.
  """

  @behaviour Plug

  import Plug.Conn

  @type drain :: :atomics.atomics_ref()

  @doc "Readiness flags for a server that hasn't started serving."
  @spec new() :: drain()
  def new, do: :atomics.new(2, [])

  @doc "Marks the server serving."
  @spec serve(drain()) :: :ok
  def serve(drain), do: :atomics.put(drain, 2, 1)

  @doc "Whether the server has started serving."
  @spec serving?(drain()) :: boolean()
  def serving?(drain), do: :atomics.get(drain, 2) == 1

  @doc "Marks the server draining."
  @spec drain(drain()) :: :ok
  def drain(drain), do: :atomics.put(drain, 1, 1)

  @doc "Whether the server is draining."
  @spec draining?(drain()) :: boolean()
  def draining?(drain), do: :atomics.get(drain, 1) == 1

  @doc "Whether the request is a health check."
  @spec check?(Plug.Conn.t()) :: boolean()
  def check?(%Plug.Conn{method: method, path_info: ["health", check]}),
    do: method in ["GET", "HEAD"] and check in ["live", "ready"]

  def check?(_conn), do: false

  @doc "Answers a request that `check?/1` accepted."
  @spec respond(Plug.Conn.t(), drain(), atom() | nil) :: Plug.Conn.t()
  def respond(%Plug.Conn{path_info: ["health", check]} = conn, drain, instance) do
    {status, body} =
      cond do
        check == "live" -> {200, "ok"}
        draining?(drain) -> {503, "draining"}
        not serving?(drain) -> {503, "starting"}
        instance != nil and Process.whereis(instance) == nil -> {503, "unavailable"}
        true -> {200, "ok"}
      end

    conn
    |> put_resp_content_type("text/plain")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> send_resp(status, body)
  end

  @impl Plug
  def init(opts) do
    %{
      drain: Keyword.fetch!(opts, :drain),
      instance: Keyword.get(opts, :instance),
      stats: Keyword.get(opts, :stats)
    }
  end

  @impl Plug
  def call(conn, %{drain: drain, instance: instance, stats: stats}) do
    cond do
      check?(conn) ->
        respond(conn, drain, instance)

      stats != nil and ImagePipeServer.Stats.check?(conn) ->
        ImagePipeServer.Stats.respond(conn, stats)

      true ->
        send_resp(conn, 404, "")
    end
  end
end
