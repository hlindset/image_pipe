Code.require_file("raw.exs", __DIR__)
jpg = File.read!(Path.expand("test/support/image_pipe/test/sources/exif_2.jpg"))
defmodule Origin do
  import Plug.Conn
  def init(o), do: o
  def call(conn, jpg) do
    Process.sleep(300)
    conn |> put_resp_content_type("image/jpeg", nil) |> send_resp(200, jpg)
  end
end
{:ok, _} = Bandit.start_link(plug: {Origin, jpg}, port: 4793, ip: {127,0,0,1})
{:ok, _} = Bandit.start_link(plug: {ImagePipe.Plug, [sources: [web: [adapter: ImagePipe.Source.HTTP, match: :path, options: [base_url: "http://127.0.0.1:4793", address_policy: [allow_loopback: true], req_options: [auth: {:bearer, "SECRETBEARER"}, headers: [{"x-api-key", "SECRETHEADER"}]]]]]]}, port: 4794, ip: {127,0,0,1})
Process.sleep(200)
parent = self()
:telemetry.attach("t", [:image_pipe, :transform, :execute, :start], fn _, _, _, _ ->
  callers = Process.get(:"$callers", [])
  send(parent, {:callers, self(), callers})
end, nil)
t = Task.async(fn -> Raw.req(4794, "GET /w=10/src/a.jpg HTTP/1.1") end)
receive do
  {:callers, me, callers} ->
    IO.inspect(callers, label: "callers of #{inspect(me)}")
    all = for pid <- Process.list(), {:dictionary, d} = Process.info(pid, :dictionary), d[:"$initial_call"] in [{ImagePipe.Delivery.Coordinator, :init, 1}], do: pid
    for c <- all, do: (try do GenServer.call(c, :bogus, 500) catch _, _ -> :ok end)
    for pid <- [], is_pid(pid) do
      st = try do :sys.get_status(pid, 1000) catch k, r -> {k, r} end
      s = inspect(st, limit: :infinity, printable_limit: :infinity)
      IO.puts("#{inspect(pid)} module=#{inspect(get_in(Process.info(pid, :dictionary) |> elem(1), [:"$initial_call"]))} has SECRETBEARER=#{String.contains?(s, "SECRETBEARER")} SECRETHEADER=#{String.contains?(s, "SECRETHEADER")}")
    end
after 5000 -> IO.puts("no fetch event")
end
IO.puts(Task.await(t) |> String.split("\r\n") |> hd)
