defmodule Echo do
  import Plug.Conn
  def init(o), do: o
  def call(conn, opts) do
    test = Keyword.fetch!(opts, :test)
    case conn.request_path do
      "/to-other" ->
        conn |> put_resp_header("location", "http://127.0.0.1:#{opts[:port]}/img") |> send_resp(302, "")
      "/to-userinfo" ->
        conn |> put_resp_header("location", "http://attacker:chosen@127.0.0.1:#{opts[:port]}/img") |> send_resp(302, "")
      _ ->
        send(test, {:hit, conn.host, conn.port, conn.request_path, conn.req_headers})
        conn |> put_resp_content_type("image/png") |> send_resp(200, "x")
    end
  end
end

port = 47811
{:ok, _} = Bandit.start_link(plug: {Echo, test: self(), port: port}, port: port, ip: {127,0,0,1}, startup_log: false)

{:ok, opts} =
  ImagePipe.Source.HTTP.validate_options(
    allowed_hosts: ["localhost:#{port}", "127.0.0.1:#{port}"],
    address_policy: [allow_loopback: true],
    max_redirects: 2,
    dns_cache: false,
    req_options: [headers: [{"x-api-key", "SECRET-KEY"}, {"authorization", "Bearer SECRET"}, {"x-goog-api-key", "G"}]]
  )

for path <- ["to-other", "to-userinfo"] do
  src = %ImagePipe.Source.URL{scheme: :http, host: "localhost", port: port, path: [path], query: nil}
  {:ok, resolved} = ImagePipe.Source.HTTP.resolve(src, opts, [])
  res = ImagePipe.Source.HTTP.fetch(resolved, opts, [])
  IO.inspect(elem(res, 0), label: "fetch #{path}")
  case res do
    {:ok, r} -> Enum.to_list(r.stream)
    _ -> :ok
  end
  receive do
    {:hit, host, p, rp, headers} ->
      IO.inspect({host, p, rp}, label: "final hop")
      IO.inspect(Enum.filter(headers, fn {k, _} -> k in ["x-api-key", "authorization", "x-goog-api-key", "host"] end), label: "headers at final hop")
  after 3000 -> IO.puts("no hit")
  end
end
