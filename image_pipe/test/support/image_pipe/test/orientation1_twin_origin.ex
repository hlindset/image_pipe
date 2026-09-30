defmodule ImagePipe.Test.Orientation1TwinOrigin do
  @moduledoc """
  Deferred-orientation (#146) twin origin plug: serves the displayed pixels of an
  EXIF-oriented source with the orientation already applied and the tag stripped.

  Configured with `{base_bytes, orientation}`: the base image bytes are decoded,
  tagged with `orientation`, re-encoded as JPEG, then re-decoded and autorotated
  into display pixels, stored untagged as a lossless orientation-1 PNG. Derived
  from the re-decoded JPEG (not the in-memory image) so the displayed frame
  exactly matches what the pipeline decodes from `ImagePipe.Test.OrientedFrameOrigin`.
  """

  use Boundary, top_level?: true, deps: []

  def init({base_bytes, orientation}), do: {base_bytes, orientation}

  def call(conn, {base_bytes, orientation}) do
    oriented =
      base_bytes
      |> Image.open!(access: :random)
      |> Image.set_orientation!(orientation)
      |> Image.write!(:memory, suffix: ".jpg")

    {:ok, {displayed, _flags}} = Image.autorotate(Image.open!(oriented, access: :random))

    body =
      displayed
      |> Image.set_orientation!(1)
      |> Image.write!(:memory, suffix: ".png")

    conn
    |> Plug.Conn.put_resp_content_type("image/png")
    |> Plug.Conn.send_resp(200, body)
  end
end
