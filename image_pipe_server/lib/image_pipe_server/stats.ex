defmodule ImagePipeServer.Stats do
  @moduledoc """
  The cache stats endpoints, on when `[stats] enabled` is set.

  `GET /stats` answers with JSON and `GET /metrics` with Prometheus text.
  Both report, for each cache, `ImagePipe.cache_stats/1` and the free and
  total space of the filesystem that holds its root. Every request must send
  `Authorization: Bearer <token>` with the stats token, or gets a 401.
  `ImagePipeServer.Router` serves them on the image listener, ahead of the
  image auth token, and `ImagePipeServer.Health` on the `health_port`
  listener.

  The disk sizes come from `ImagePipeServer.Stats.Disk`, which reads them in
  the background, so a request never waits for `df`.

  The options are a map with `:token_hash` (the SHA-256 of the token),
  `:instance` (the ImagePipe instance name), `:disk` (the
  `ImagePipeServer.Stats.Disk` name), and `:roots`, each cache's root by its
  `ImagePipe.cache_stats/1` name.
  """

  import Plug.Conn

  alias ImagePipeServer.Stats.Disk

  @type options :: %{
          token_hash: binary(),
          instance: atom(),
          disk: atom(),
          roots: %{optional(:output) => Path.t()}
        }

  @doc "Whether the request is for a stats endpoint."
  @spec check?(Plug.Conn.t()) :: boolean()
  def check?(%Plug.Conn{method: method, path_info: [path]}),
    do: method in ["GET", "HEAD"] and path in ["stats", "metrics"]

  def check?(_conn), do: false

  @doc "Answers a request that `check?/1` accepted."
  @spec respond(Plug.Conn.t(), options()) :: Plug.Conn.t()
  def respond(conn, %{token_hash: hash} = opts) do
    if ImagePipeServer.Auth.authorized?(conn, hash) do
      case snapshot(opts) do
        {:ok, snapshot} -> render(conn, conn.path_info, snapshot)
        :unavailable -> send_resp(conn, 503, "unavailable")
      end
    else
      ImagePipeServer.Auth.challenge(conn)
    end
  end

  defp render(conn, ["stats"], snapshot) do
    body =
      Map.new(snapshot, fn {cache, stats} ->
        case Map.pop(stats, :counting?) do
          {nil, stats} -> {cache, stats}
          {counting, stats} -> {cache, Map.put(stats, :counting, counting)}
        end
      end)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, JSON.encode!(body))
  end

  defp render(conn, ["metrics"], snapshot) do
    conn
    |> put_resp_header("content-type", "text/plain; version=0.0.4; charset=utf-8")
    |> send_resp(200, prometheus(snapshot))
  end

  # The health listener runs while the instance starts and drains, when
  # there are no stats to read, as `/health/ready` answers then too.
  defp snapshot(%{instance: instance, roots: roots, disk: disk}) do
    with {:ok, stats} <- cache_stats(instance), do: {:ok, read_snapshot(stats, roots, disk)}
  end

  defp cache_stats(instance) do
    {:ok, ImagePipe.cache_stats(instance)}
  rescue
    ArgumentError -> :unavailable
  end

  defp read_snapshot(stats, roots, disk) do
    Map.new(stats, fn {cache, stats} ->
      {cache, Map.merge(stats, Disk.read(disk, Map.fetch!(roots, cache)))}
    end)
  end

  @gauges [
    bytes: "Bytes the cache stores.",
    max_bytes: "The cache's size cap in bytes.",
    entries: "Entries the cache stores.",
    counting?: "1 until the cache has counted the entries on disk at startup.",
    refused: "1 when another node owns the cache's root, so this node doesn't use it.",
    available: "0 when the cache didn't report its bytes and entries within a second.",
    disk_free_bytes: "Free bytes on the filesystem that holds the cache root.",
    disk_total_bytes: "Total bytes of the filesystem that holds the cache root.",
    disk_age_seconds: "Seconds since the disk sizes were read."
  ]

  @lookups [hit: :hits, miss: :misses]

  defp prometheus(snapshot) do
    caches = Enum.sort(snapshot)
    # A refused cache has no counts.
    counted = Enum.reject(caches, fn {_cache, stats} -> stats.refused end)

    gauges =
      for {field, help} <- @gauges do
        name = "image_pipe_cache_" <> String.trim_trailing(Atom.to_string(field), "?")

        samples =
          for {cache, stats} <- caches,
              value = sample(stats[field]),
              value != nil,
              do: [name, ~s({cache="), Atom.to_string(cache), ~s("} ), value, ?\n]

        [header(name, help, "gauge"), samples]
      end

    read_errors = [
      header(
        "image_pipe_cache_read_errors_total",
        "Stored entries the cache couldn't read since start, also counted as misses.",
        "counter"
      ),
      for {cache, stats} <- counted do
        [
          ~s(image_pipe_cache_read_errors_total{cache="),
          Atom.to_string(cache),
          ~s("} ),
          Integer.to_string(stats.read_errors),
          ?\n
        ]
      end
    ]

    lookups = [
      header(
        "image_pipe_cache_lookups_total",
        "Cache lookups since start, by result.",
        "counter"
      ),
      for {cache, stats} <- counted, {result, field} <- @lookups do
        [
          ~s(image_pipe_cache_lookups_total{cache="),
          Atom.to_string(cache),
          ~s(",result="),
          Atom.to_string(result),
          ~s("} ),
          Integer.to_string(Map.fetch!(stats, field)),
          ?\n
        ]
      end
    ]

    IO.iodata_to_binary([gauges, lookups, read_errors])
  end

  defp header(name, help, type),
    do: ["# HELP ", name, " ", help, "\n# TYPE ", name, " ", type, "\n"]

  defp sample(nil), do: nil
  defp sample(true), do: "1"
  defp sample(false), do: "0"
  defp sample(value) when is_integer(value), do: Integer.to_string(value)
end
