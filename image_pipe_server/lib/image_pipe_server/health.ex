defmodule ImagePipeServer.Health do
  @moduledoc """
  Liveness and readiness checks, and the drain flag readiness follows.

  `GET /health/live` answers `200` while the server runs. `GET /health/ready`
  answers `200` until the server starts draining on shutdown, then `503`.
  `ImagePipeServer.Router` serves both on the image listener. As a plug,
  this module serves only them, on the listener `[server] health_port`
  starts, and answers `404` to anything else.
  """

  @behaviour Plug

  import Plug.Conn

  @type drain :: :atomics.atomics_ref()

  @doc "A drain flag, not yet draining."
  @spec new() :: drain()
  def new, do: :atomics.new(1, [])

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
  @spec respond(Plug.Conn.t(), drain()) :: Plug.Conn.t()
  def respond(%Plug.Conn{path_info: ["health", check]} = conn, drain) do
    status = if check == "ready" and draining?(drain), do: 503, else: 200

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, if(status == 200, do: "ok", else: "draining"))
  end

  @impl Plug
  def init(opts), do: Keyword.fetch!(opts, :drain)

  @impl Plug
  def call(conn, drain) do
    if check?(conn), do: respond(conn, drain), else: send_resp(conn, 404, "")
  end
end
