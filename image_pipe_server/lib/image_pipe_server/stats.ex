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

  @in_flight __MODULE__.InFlight

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

  @doc false
  # The roots with a `df` running, so a mount that hangs it gets one stuck
  # process rather than one per scrape. The application's starting process
  # owns the table.
  def create_table, do: :ets.new(@in_flight, [:named_table, :public, :set])

  defp snapshot(%{instance: instance, roots: roots}) do
    stats = ImagePipe.cache_stats(instance)

    stats
    |> Map.keys()
    |> Task.async_stream(&{&1, disk(Map.fetch!(roots, &1))},
      max_concurrency: max(map_size(stats), 1),
      timeout: :infinity
    )
    |> Map.new(fn {:ok, {cache, disk}} -> {cache, Map.merge(Map.fetch!(stats, cache), disk)} end)
  end

  @df_timeout 2_000
  @unknown %{disk_free_bytes: nil, disk_total_bytes: nil}

  # POSIX `df` for the filesystem that holds `root`, sizes in KiB. It runs
  # without a shell, and without `-l`, so a network or FUSE volume reports
  # too. A scrape waits at most `@df_timeout` for it. A `df` stuck on a dead
  # mount can't be killed from here, so no other starts for that root until
  # it ends, and scrapes report no sizes meanwhile.
  defp disk(root) do
    if :ets.insert_new(@in_flight, {root}) do
      reply = :erlang.alias()

      spawn(fn ->
        result =
          try do
            System.cmd("df", ["-kP", "--", root])
          rescue
            _missing_or_failed -> :error
          after
            :ets.delete(@in_flight, root)
          end

        send(reply, {reply, result})
      end)

      receive do
        {^reply, {output, 0}} -> parse_df(output)
        {^reply, _failed} -> @unknown
      after
        @df_timeout ->
          :erlang.unalias(reply)
          @unknown
      end
    else
      @unknown
    end
  end

  # The last line: filesystem, total, used, available, capacity, mount point.
  # The filesystem name or mount point can hold spaces, so the sizes are the
  # three fields before the capacity percentage.
  defp parse_df(output) do
    fields = output |> String.trim() |> String.split("\n") |> List.last() |> String.split()

    with [total, _used, available, _capacity | _mount] <- from_sizes(fields),
         {total, ""} when total > 0 <- Integer.parse(total),
         {available, ""} <- Integer.parse(available) do
      %{disk_free_bytes: available * 1024, disk_total_bytes: total * 1024}
    else
      _unreadable -> @unknown
    end
  end

  defp from_sizes([_total, _used, _available, capacity | _rest] = fields) do
    if String.ends_with?(capacity, "%"),
      do: fields,
      else: from_sizes(tl(fields))
  end

  defp from_sizes(_fields), do: nil

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
