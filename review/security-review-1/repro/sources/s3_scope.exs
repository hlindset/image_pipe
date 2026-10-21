defmodule Meta do
  import Plug.Conn
  def init(o), do: o
  def call(%{request_path: "/creds"} = conn, _) do
    :ets.update_counter(:c, :creds, 1)
    exp = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()
    body = JSON.encode!(%{"AccessKeyId" => "AKID", "SecretAccessKey" => "S", "Token" => "T", "Expiration" => exp})
    conn |> put_resp_content_type("application/json") |> send_resp(200, body)
  end
  def call(conn, _) do
    :ets.update_counter(:c, :s3, 1)
    send_resp(conn, 404, "")
  end
end
:ets.new(:c, [:named_table, :public]); :ets.insert(:c, [{:creds, 0}, {:s3, 0}])
port = 47833
{:ok, _} = Bandit.start_link(plug: Meta, port: port, ip: {127,0,0,1}, startup_log: false)
config = ImagePipe.Plug.init(
  sources: [s3: [adapter: ImagePipe.Source.S3, match: [scheme: "s3"],
    options: [default: [region: "us-east-1", endpoint: "http://127.0.0.1:#{port}",
      credentials: {:provider, ImagePipe.Source.S3.ContainerCredentials, full_uri: "http://127.0.0.1:#{port}/creds"}]]]])
before = DynamicSupervisor.count_children(ImagePipe.Source.S3.RefreshCache.DynamicSupervisor).active
for i <- 1..200 do
  conn = Plug.Test.conn(:get, "/src/s3://rnd-#{i}-#{System.unique_integer([:positive])}/x.png") |> ImagePipe.Plug.call(config)
  if i == 1, do: IO.inspect(conn.status, label: "first status")
end
IO.inspect(:ets.tab2list(:c), label: "endpoint hits")
IO.inspect(DynamicSupervisor.count_children(ImagePipe.Source.S3.RefreshCache.DynamicSupervisor).active - before, label: "new credential entry processes")
