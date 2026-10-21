defmodule Origin do
  import Plug.Conn
  def init(o), do: o
  def call(conn, _opts) do
    n = :ets.update_counter(:wm, :cur, 1)
    :ets.update_counter(:wm, :hits, 1)
    max = :ets.lookup_element(:wm, :max, 2)
    if n > max, do: :ets.insert(:wm, {:max, n})
    Process.sleep(400)
    :ets.update_counter(:wm, :cur, -1)
    {:ok, img} = Image.new(4, 4, color: [255, 0, 0])
    body = Image.write!(img, :memory, suffix: ".png")
    conn |> put_resp_content_type("image/png") |> send_resp(200, body)
  end
end
:ets.new(:wm, [:named_table, :public])
:ets.insert(:wm, [{:cur, 0}, {:max, 0}, {:hits, 0}])
port = 47822
{:ok, _} = Bandit.start_link(plug: Origin, port: port, ip: {127,0,0,1}, startup_log: false)
base = "http://127.0.0.1:#{port}"
config = ImagePipe.Plug.init(
  sources: [web: [adapter: ImagePipe.Source.HTTP, match: [scheme: ["http"]],
    options: [allowed_hosts: ["127.0.0.1:#{port}"], address_policy: [allow_loopback: true], dns_cache: false]]],
  request_watermarks: true)
n = String.to_integer(System.get_env("N", "31"))
groups = for i <- 1..n, do: "wm-src64=" <> Base.url_encode64("#{base}/wm#{i}.png", padding: false)
path = "/" <> Enum.join(groups, "/-/") <> "/format=png/src/#{base}/main.png"
IO.puts("segments: #{length(String.split(path, "/")) - 1}")
t = System.monotonic_time(:millisecond)
conn = Plug.Test.conn(:get, path) |> ImagePipe.Plug.call(config)
IO.inspect({conn.status, String.slice(conn.resp_body, 0, 200)}, label: "status")
IO.inspect(:ets.tab2list(:wm), label: "origin counters")
IO.puts("elapsed ms #{System.monotonic_time(:millisecond) - t}")
