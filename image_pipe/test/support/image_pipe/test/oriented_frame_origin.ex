defmodule ImagePipe.Test.OrientedFrameOrigin do
  @moduledoc """
  Deferred-orientation (#146) origin plug: serves a stored image tagged with an
  EXIF orientation, so the pipeline must autorotate it.

  Configured with `{base_bytes, orientation}`: the base image bytes are decoded,
  tagged with `orientation`, and re-encoded as JPEG (which carries the EXIF tag).
  Paired with `ImagePipe.Test.Orientation1TwinOrigin`, which serves the SAME
  displayed pixels with the orientation already applied and the tag stripped, it
  is the wire-vs-orientation-1 oracle for orientation handling.
  """

  use Boundary, top_level?: true, deps: []

  def init({base_bytes, orientation}), do: {base_bytes, orientation}

  def call(conn, {base_bytes, orientation}) do
    body =
      base_bytes
      |> Image.open!(access: :random)
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
