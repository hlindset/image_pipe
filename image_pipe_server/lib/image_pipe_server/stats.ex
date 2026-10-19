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

  The options are a map with `:token_hash` (the SHA-256 of the token),
  `:instance` (the ImagePipe instance name), and `:roots`, each cache's root
  by its `ImagePipe.cache_stats/1` name.
  """

  import Plug.Conn

  @type options :: %{
          token_hash: binary(),
          instance: atom(),
          roots: %{optional(:output | :input) => Path.t()}
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
      render(conn, conn.path_info, snapshot(opts))
    else
      ImagePipeServer.Auth.challenge(conn)
    end
  end

  defp render(conn, ["stats"], snapshot) do
    body =
      Map.new(snapshot, fn {cache, stats} ->
        {cache, stats |> Map.delete(:counting?) |> Map.put(:counting, stats.counting?)}
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

  defp snapshot(%{instance: instance, roots: roots}) do
    instance
    |> ImagePipe.cache_stats()
    |> Map.new(fn {cache, stats} -> {cache, Map.merge(stats, disk(Map.fetch!(roots, cache)))} end)
  end

  # `df` for the filesystem that holds `root`, through `os_mon`. Its sizes
  # are in KiB, and all zeros when the space can't be read.
  defp disk(root) do
    case :disksup.get_disk_info(String.to_charlist(root)) do
      [{_id, total, available, _capacity}] when total > 0 ->
        %{disk_free_bytes: available * 1024, disk_total_bytes: total * 1024}

      _unknown ->
        %{disk_free_bytes: nil, disk_total_bytes: nil}
    end
  end

  @gauges [
    bytes: "Bytes the cache stores.",
    max_bytes: "The cache's size cap in bytes.",
    entries: "Entries the cache stores.",
    counting?: "1 until the cache has counted the entries on disk at startup.",
    disk_free_bytes: "Free bytes on the filesystem that holds the cache root.",
    disk_total_bytes: "Total bytes of the filesystem that holds the cache root."
  ]

  @lookups [hit: :hits, miss: :misses]

  defp prometheus(snapshot) do
    caches = Enum.sort(snapshot)

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
      for {cache, stats} <- caches do
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
      for {cache, stats} <- caches, {result, field} <- @lookups do
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
