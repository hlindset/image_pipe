defmodule ImagePipe.Plug.StreamAbortedError do
  @moduledoc """
  Raised by `ImagePipe.Plug` when a response fails after its `200` status and
  headers were sent.

  The response can't become an error response at that point. Raising makes the
  HTTP server close the connection without completing the body, so clients and
  CDNs see the response as truncated rather than complete. ImagePipe has
  already logged the underlying failure. Its status is `500`.
  """

  defexception message: "image response failed after its headers were sent",
               plug_status: 500
end
