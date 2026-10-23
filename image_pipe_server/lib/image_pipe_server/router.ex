defmodule ImagePipeServer.Router do
  @moduledoc """
  Routes requests to the health checks or to the ImagePipe mount.

  The health checks (see `ImagePipeServer.Health`) stay at the root whatever
  the mount path. Requests outside the mount path answer 404. `:image_pipe`
  takes options already initialized with `ImagePipe.Plug.init/1`. While the
  `:drain` flag is set, every response carries `connection: close`, so
  keep-alive clients reconnect to another replica.

  With `:auth_token_hash` (the SHA-256 of the auth token), requests other than
  the health checks and the stats endpoints must send
  `Authorization: Bearer <token>`, or get a 401. The token is checked before
  the mount path, so a request outside it without the token gets a 401, not
  a 404. With `:stats` (see
  `ImagePipeServer.Stats`), `/stats` and `/metrics` answer with the cache
  stats, behind their own token.

  With `:log_requests`, the 401 and the 404 outside the mount path, which
  the router answers itself, each log a request line like ImagePipe's: the
  401 at `warning`, the 404 at `info`. Health checks and stats requests log
  nothing.

  Every response carries an `x-request-id`, which is also the `:request_id`
  Logger metadata for the request. With `:trust_request_id`, an incoming ID
  of 1 to 200 letters, digits, and `-_.:+/=` is kept. Otherwise the router
  generates one, so a client can't add fields to log lines.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias ImagePipeServer.Auth
  alias ImagePipeServer.Health
  alias ImagePipeServer.Stats

  @request_id ~r"\A[A-Za-z0-9\-_.:+/=]{1,200}\z"

  @impl Plug
  def init(opts) do
    %{
      trust_request_id: Keyword.get(opts, :trust_request_id, false),
      drain: Keyword.get_lazy(opts, :drain, &Health.new/0),
      instance: Keyword.get(opts, :instance),
      mount: Plug.Router.Utils.split(Keyword.fetch!(opts, :mount_path)),
      image_pipe: Keyword.fetch!(opts, :image_pipe),
      auth_token_hash: Keyword.get(opts, :auth_token_hash),
      stats: Keyword.get(opts, :stats),
      log_requests: Keyword.get(opts, :log_requests, false)
    }
  end

  @impl Plug
  def call(conn, opts) do
    request_id = request_id(conn, opts.trust_request_id)
    Logger.metadata(request_id: request_id)

    conn
    |> put_resp_header("x-request-id", request_id)
    |> close_while_draining(opts.drain)
    |> dispatch(opts)
  end

  defp close_while_draining(conn, drain) do
    if Health.draining?(drain),
      do: put_resp_header(conn, "connection", "close"),
      else: conn
  end

  defp request_id(conn, true) do
    case get_req_header(conn, "x-request-id") do
      [id | _rest] -> if Regex.match?(@request_id, id), do: id, else: Plug.RequestId.generate()
      [] -> Plug.RequestId.generate()
    end
  end

  defp request_id(_conn, false), do: Plug.RequestId.generate()

  defp dispatch(conn, opts) do
    cond do
      Health.check?(conn) -> Health.respond(conn, opts.drain, opts.instance)
      opts.stats != nil and Stats.check?(conn) -> Stats.respond(conn, opts.stats)
      is_binary(opts.auth_token_hash) -> authorize(conn, opts, System.monotonic_time())
      true -> route(conn, opts, System.monotonic_time())
    end
  end

  defp authorize(conn, %{auth_token_hash: hash} = opts, started) do
    if Auth.authorized?(conn, hash),
      do: route(conn, opts, started),
      else: conn |> Auth.challenge() |> log_request(:warning, opts, started)
  end

  defp route(conn, %{mount: mount, image_pipe: image_pipe} = opts, started) do
    case strip_prefix(conn.path_info, mount) do
      {:ok, rest} -> Plug.forward(conn, rest, ImagePipe.Plug, image_pipe)
      :error -> conn |> send_resp(404, "") |> log_request(:info, opts, started)
    end
  end

  # The line and its fields match ImagePipe's request lines, with the path
  # cut at its source the same way.
  defp log_request(conn, level, %{log_requests: true} = opts, started) do
    Logger.log(level, fn ->
      fields = %{
        method: conn.method,
        path: log_path(conn, opts.mount),
        status: conn.status,
        duration_ms:
          System.convert_time_unit(System.monotonic_time() - started, :native, :millisecond)
      }

      {"#{fields.method} #{fields.path} #{fields.status} #{fields.duration_ms}ms",
       image_pipe: fields}
    end)

    conn
  end

  defp log_request(conn, _level, _opts, _started), do: conn

  # Under the mount, only the part after the mount path is cut at its source,
  # as in ImagePipe's own lines, so a mount segment such as `enc` isn't taken
  # for a source marker.
  defp log_path(conn, mount) do
    path = conn.request_path

    rest =
      case strip_prefix(conn.path_info, mount) do
        {:ok, _rest} -> drop_segments(path, length(mount))
        :error -> path
      end

    binary_part(path, 0, byte_size(path) - byte_size(rest)) <>
      ImagePipe.Telemetry.request_path(rest, conn.query_string)
  end

  # Drops the first `count` segments by their raw bytes, skipping empty ones
  # as `path_info` does.
  defp drop_segments(path, 0), do: path

  defp drop_segments(path, count) do
    segment_and_rest = String.trim_leading(path, "/")

    case :binary.match(segment_and_rest, "/") do
      {offset, _length} ->
        drop_segments(
          binary_part(segment_and_rest, offset, byte_size(segment_and_rest) - offset),
          count - 1
        )

      :nomatch ->
        ""
    end
  end

  defp strip_prefix(path, []), do: {:ok, path}
  defp strip_prefix([segment | path], [segment | mount]), do: strip_prefix(path, mount)
  defp strip_prefix(_path, _mount), do: :error
end
