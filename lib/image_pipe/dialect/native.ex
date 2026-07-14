defmodule ImagePipe.Dialect.Native do
  @moduledoc """
  Plug entry point for ImagePipe's native URL dialect.

  Unlike `ImagePipe.Plug` (which dispatches through the framework's
  `Parser`/`Request`/`Resolver`/`Renderer` stack), this dialect owns its
  whole request chain end to end, assembled directly from ImagePipe's core
  toolkit. It depends on the core; the core never depends on it.

  This module is currently a skeleton: `call/2` returns `501` on every
  request. It is replaced task by task as the native dialect's request chain
  is built out.

  ## Mount prefix caveat

  `ImagePipe.Dialect.Native.Path` strips the mount prefix from the raw
  request path by treating `conn.script_name` (Plug's *decoded* segment
  list) as a byte-exact raw string prefix of `conn.request_path`. This is
  only correct when the mount path is canonical unescaped ASCII. A
  `script_name` segment that round-trips unequal through percent-encoding
  is host misconfiguration and raises at request runtime (500-class, never
  a client 400) — non-canonical/escaped mount paths are unsupported in v1.
  A config-supplied raw mount prefix is the future escape hatch.
  """

  use Boundary,
    top_level?: true,
    deps: [
      ImagePipe.Cache,
      # ImagePipe.Decode,            # added in Task 12
      ImagePipe.Error,
      ImagePipe.Format,
      ImagePipe.Output,
      ImagePipe.Plan,
      # ImagePipe.Representation,    # added in Task 9
      ImagePipe.Response,
      ImagePipe.Source,
      ImagePipe.Telemetry,
      ImagePipe.Transform
    ],
    exports: []

  @behaviour Plug

  alias ImagePipe.Dialect.Native.Config

  @impl Plug
  def init(opts), do: Config.validate!(opts)

  @impl Plug
  def call(%Plug.Conn{} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("text/plain")
    |> Plug.Conn.send_resp(501, "not implemented")
  end
end
