# Run from image_pipe/, one mode per VM:
# mise exec -- mix run bench/warm_requests.exs get|head|get-concurrent [IMAGE]
#
# Times warm output-cache hits through ImagePipe.Plug for a local file source
# and a bounded filesystem cache, after one cold request fills the cache.
defmodule WarmRequestsBench do
  import Plug.Test

  @requests 2_000
  @concurrency 8

  def run([mode | rest]) do
    image = List.first(rest, "priv/static/images/waterfall.jpg")
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

    path = "/w=300/format=webp/src/image.jpg"
    method = if mode == "head", do: :head, else: :get
    %{status: 200} = ImagePipe.Plug.call(conn(:get, path), mount)
    request = fn -> %{status: 200} = ImagePipe.Plug.call(conn(method, path), mount) end
    Enum.each(1..100, fn _ -> request.() end)

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
        requests: @requests,
        total_ms: elapsed / 1_000,
        us_per_request: elapsed / @requests
      })
    )
  after
    File.rm_rf!(Path.join(System.tmp_dir!(), "warm-bench-*"))
  end
end

WarmRequestsBench.run(System.argv())
