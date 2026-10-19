defmodule ImagePipeServer.Auth do
  @moduledoc false
  # Bearer token checks for the image auth token and the stats token.

  import Plug.Conn

  # Comparing digests keeps the comparison constant-time for any token length.
  # The scheme is case-insensitive (RFC 9110 §11.1).
  @spec authorized?(Plug.Conn.t(), binary()) :: boolean()
  def authorized?(conn, hash) do
    with [<<scheme::binary-size(7), token::binary>>] <- get_req_header(conn, "authorization"),
         "bearer " <- String.downcase(scheme) do
      Plug.Crypto.secure_compare(:crypto.hash(:sha256, token), hash)
    else
      _other -> false
    end
  end

  @spec challenge(Plug.Conn.t()) :: Plug.Conn.t()
  def challenge(conn) do
    conn
    |> put_resp_header("www-authenticate", "Bearer")
    |> send_resp(401, "")
  end
end
