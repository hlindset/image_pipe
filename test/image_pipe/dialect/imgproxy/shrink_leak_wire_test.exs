defmodule ImagePipe.Dialect.Imgproxy.ShrinkLeakWireTest do
  @moduledoc """
  Wire-level guard that the realized shrink-on-load factor from one pipeline
  does not leak past the residual resize into a *later* pipeline's absolute
  crop (#180). imgproxy has a single pipeline and discards its Context preshrink
  factor each frame; ImagePipe's `/-/` chaining is a dialect-specific extension,
  so the residual resize must clear `decode_shrink` or pipeline 2's absolute crop
  gets divided by the stale factor.

  Multi-pipeline `/-/` is imgproxy-dialect syntax with no IIIF equivalent, so
  this coverage lives on the dialect surface.
  These drive full requests through `ImagePipe.Plug.init/1` + `call/2`
  mounting `ImagePipe.Dialect.Imgproxy`, over `beach.jpg` (4000×2667, JPEG-shrink-eligible) and assert the
  decoded output dimensions.
  """

  use ExUnit.Case, async: true

  import Plug.Test

  alias ImagePipe.Dialect.Imgproxy

  defp call(path) do
    opts =
      ImagePipe.Plug.init(
        dialect: Imgproxy,
        sources: [path: {ImagePipe.Source.File, root: "priv/static", root_id: "static"}],
        max_body_bytes: 20_000_000,
        max_input_pixels: 40_000_000
      )

    :get
    |> conn(path)
    |> ImagePipe.Plug.call(opts)
  end

  defp dimensions(conn) do
    img = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    {Image.width(img), Image.height(img)}
  end

  # Pipeline 1: beach.jpg 4000×2667, fit:500:500 triggers shrink-on-load and
  # leaves a residual resize with a non-trivial `decode_shrink`. Pipeline 2: a
  # center crop of 200×200 (absolute pixels) on the live post-resize image. With
  # the leak the crop is rescaled down by the stale factor; cleared, it is the
  # requested 200×200.
  test "shrink-on-load factor does not leak past the residual resize into a later pipeline" do
    conn = call("/unsafe/rs:fit:500:500/-/c:200:200/f:jpeg/plain/images/beach.jpg")

    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
  end

  # Complement: when pipeline 1 does NOT trigger shrink-on-load (fit:3000:3000
  # against 4000×2667 → factor ~1.33, no power-of-2 shrink), the same pipeline-2
  # absolute crop is still exactly 200×200. Brackets the behavior so the crop
  # result is independent of whether the decode shrank.
  test "later-pipeline absolute crop is exact when pipeline 1 did not shrink" do
    conn = call("/unsafe/rs:fit:3000:3000/-/c:200:200/f:jpeg/plain/images/beach.jpg")

    assert conn.status == 200
    assert dimensions(conn) == {200, 200}
  end
end
