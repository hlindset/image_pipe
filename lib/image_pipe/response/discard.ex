defmodule ImagePipe.Response.Discard do
  @moduledoc false
  @behaviour Plug.Conn.Adapter
  @impl true
  def send_resp(payload, _status, _headers, _body), do: {:ok, nil, payload}
  @impl true
  def send_chunked(payload, _status, _headers), do: {:ok, nil, payload}
  @impl true
  def chunk(payload, _body), do: {:ok, nil, payload}
  @impl true
  def send_file(payload, _status, _headers, _path, _offset, _length), do: {:ok, nil, payload}
  @impl true
  def read_req_body(payload, _opts), do: {:ok, "", payload}
  @impl true
  def inform(payload, _status, _headers), do: {:ok, payload}
  @impl true
  def upgrade(_payload, _protocol, _opts), do: {:error, :not_supported}
  @impl true
  def get_peer_data(_payload), do: %{address: {127, 0, 0, 1}, port: 0, ssl_cert: nil}
  @impl true
  def get_http_protocol(_payload), do: :"HTTP/1.1"
end
