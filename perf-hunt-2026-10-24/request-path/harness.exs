defmodule H do
  import Plug.Test

  def setup(opts \\ []) do
    image = Keyword.get(opts, :image, "priv/static/images/waterfall.jpg")
    root = Path.join(System.tmp_dir!(), "hbench-#{System.unique_integer([:positive])}")
    sources = Path.join(root, "sources")
    File.mkdir_p!(sources)
    File.cp!(image, Path.join(sources, "image.jpg"))
    File.touch!(Path.join(sources, "image.jpg"), System.os_time(:second) - 60)
    nested = Path.join([sources, "a", "b", "c"])
    File.mkdir_p!(nested)
    File.cp!(image, Path.join(nested, "image.jpg"))
    File.touch!(Path.join(nested, "image.jpg"), System.os_time(:second) - 60)
    name = Module.concat(H, "I#{System.unique_integer([:positive])}")

    extra = Keyword.get(opts, :extra, [])

    {:ok, _} =
      Supervisor.start_link(
        [
          {ImagePipe,
           [
             name: name,
             allow_unsigned: Keyword.get(opts, :allow_unsigned, true),
             max_body_bytes: 100_000_000,
             max_input_pixels: 60_000_000,
             sources: [
               path: [
                 adapter: ImagePipe.Source.File,
                 match: :path,
                 options: [root: sources, root_id: "bench"]
               ]
             ],
             cache: [root: Path.join(root, "output"), max_size_bytes: 100_000_000]
           ] ++ extra}
        ],
        strategy: :one_for_one
      )

    mount = ImagePipe.Plug.init([instance: name] ++ Keyword.get(opts, :mount, []))
    %{mount: mount, root: root, name: name}
  end

  def call(mount, method, path, headers \\ []) do
    conn = Enum.reduce(headers, conn(method, path), fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)
    r = ImagePipe.Plug.call(conn, mount)
    drain()
    r
  end

  def drain do
    receive do
      {:plug_conn, :sent} -> drain()
      {ref, _} when is_reference(ref) -> drain()
    after
      0 -> :ok
    end
  end

  # per-request reductions and heap allocation (words) in the calling process
  def cost(fun, n \\ 500) do
    Enum.each(1..50, fn _ -> fun.() end)
    :erlang.garbage_collect()
    {:reductions, r0} = Process.info(self(), :reductions)
    t0 = System.monotonic_time(:microsecond)
    Enum.each(1..n, fn _ -> fun.() end)
    t1 = System.monotonic_time(:microsecond)
    {:reductions, r1} = Process.info(self(), :reductions)
    %{us: (t1 - t0) / n, reductions: div(r1 - r0, n)}
  end

  def tprof(fun, n \\ 300, type \\ :call_time) do
    Enum.each(1..50, fn _ -> fun.() end)

    {:ok, _} =
      :tprof.profile(fn -> Enum.each(1..n, fn _ -> fun.() end) end, %{type: type, report: {:inspect, []}})
      |> then(&{:ok, &1})
  end
end
