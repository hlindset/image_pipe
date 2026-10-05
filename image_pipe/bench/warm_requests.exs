# Run from image_pipe/, one mode per VM:
# mise exec -- mix run bench/warm_requests.exs get|head|get-concurrent|bandit [WIDTH] [IMAGE]
#
# Times warm output-cache hits through ImagePipe.Plug for a local file source
# and a bounded filesystem cache, after one cold request fills the cache.
# `bandit` serves the mount over loopback HTTP/1.1 and reads each response
# on one keep-alive connection; the other modes call the Plug directly.
defmodule WarmRequestsBench do
  import Plug.Test

  @requests 2_000
  @concurrency 8

  def run([mode | rest]) do
    width = rest |> Enum.at(0, "300") |> String.to_integer()
    image = Enum.at(rest, 1, "priv/static/images/waterfall.jpg")
    root = Path.join(System.tmp_dir!(), "warm-bench-#{System.unique_integer([:positive])}")
    sources = Path.join(root, "sources")
    File.mkdir_p!(sources)
    File.cp!(image, Path.join(sources, "image.jpg"))
    # The file source keeps no stat evidence for a file changed this second.
    File.touch!(Path.join(sources, "image.jpg"), System.os_time(:second) - 60)

    cache_opts = [
      root: Path.join(root, "output"),
      node_id: "bench",
      max_size_bytes: 100_000_000
    ]

    {:ok, _} =
      Supervisor.start_link(
        [
          {ImagePipe,
           name: WarmRequestsBench.Instance,
           max_body_bytes: 100_000_000,
           max_input_pixels: 60_000_000,
           sources: [
             path: [
               adapter: ImagePipe.Source.File,
               match: :path,
               options: [root: sources, root_id: "bench"]
             ]
           ],
           cache: {ImagePipe.Cache.FileSystem, cache_opts}}
        ],
        strategy: :one_for_one
      )

    mount = ImagePipe.Plug.init(instance: WarmRequestsBench.Instance)

    path = "/w=#{width}/format=webp/src/image.jpg"
    method = if mode == "head", do: :head, else: :get
    %{status: 200, resp_body: body} = ImagePipe.Plug.call(conn(:get, path), mount)
    drain_sent()

    request = fn ->
      %{status: 200} = ImagePipe.Plug.call(conn(method, path), mount)
      drain_sent()
    end

    Enum.each(1..100, fn _ -> request.() end)

    request =
      case mode do
        "bandit" -> bandit_client(mount, path)
        _plug -> request
      end

    {elapsed, _} =
      :timer.tc(fn ->
        case mode do
          "get-concurrent" ->
            1..@concurrency
            |> Task.async_stream(
              fn _ -> Enum.each(1..div(@requests, @concurrency), fn _ -> request.() end) end,
              timeout: :infinity
            )
            |> Stream.run()

          _sequential ->
            Enum.each(1..@requests, fn _ -> request.() end)
        end
      end)

    IO.puts(
      JSON.encode!(%{
        mode: mode,
        body_bytes: byte_size(body),
        requests: @requests,
        total_ms: elapsed / 1_000,
        us_per_request: elapsed / @requests
      })
    )
  after
    System.tmp_dir!() |> Path.join("warm-bench-*") |> Path.wildcard() |> Enum.each(&File.rm_rf!/1)
  end

  # Plug.Test sends each response, body included, to the calling process.
  # Left unread, they pile up and slow later requests.
  defp drain_sent do
    receive do
      {:plug_conn, :sent} -> drain_sent()
      {ref, _response} when is_reference(ref) -> drain_sent()
    after
      0 -> :ok
    end
  end

  defmodule Mounted do
    def init(mount), do: mount
    def call(conn, mount), do: ImagePipe.Plug.call(conn, mount)
  end

  defp bandit_client(mount, path) do
    {:ok, bandit} =
      Bandit.start_link(plug: {Mounted, mount}, port: 0, ip: :loopback, startup_log: false)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
    request = "GET #{path} HTTP/1.1\r\nhost: localhost\r\n\r\n"

    fn ->
      :ok = :gen_tcp.send(socket, request)
      read_response(socket, "")
    end
  end

  defp read_response(socket, acc) do
    case :binary.split(acc, "\r\n\r\n") do
      [head, body] ->
        "HTTP/1.1 200" <> _ = head
        [_, length] = Regex.run(~r/content-length: (\d+)/, head)
        read_body(socket, body, String.to_integer(length))

      [_partial] ->
        {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
        read_response(socket, acc <> data)
    end
  end

  defp read_body(_socket, body, length) when byte_size(body) == length, do: :ok

  defp read_body(socket, body, length) do
    {:ok, data} = :gen_tcp.recv(socket, 0, 5_000)
    read_body(socket, body <> data, length)
  end
end

WarmRequestsBench.run(System.argv())
