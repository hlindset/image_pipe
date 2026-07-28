defmodule ImagePipe.Dialect.ColorCarryParityTest do
  use ExUnit.Case, async: true

  # The delivery-boundary color carry (`InputColorManagement.stamp_carry/1`) is
  # what tells `Output.Encoder`'s colorspace-to-result step that an ICC import
  # ran and what the source profile was. A dialect that never stamps it makes
  # the encoder take the `imported == false` branch on an image that WAS
  # imported — which double-converts (strip) or skips the re-export (preserve).
  #
  # THE TRAP this file exists to close: both mistakes leave the OUTPUT PROFILE
  # HEADER identical to the sibling dialect's, so every header/field assertion
  # passes while the pixels are wrong. These tests therefore compare decoded
  # PIXELS across the two dialects and never a header.
  #
  # The source is the committed wide-gamut fixture (`profile?: true` in
  # `SourceInventory`); nearly every other fixture is profile-less, which is
  # exactly why this hid.

  import Plug.Test

  # Both arms are named explicitly, per function. The imgproxy conformance
  # suite's no-alias rule does not apply here: that file compiles ONE body
  # twice and an alias would silently pin both arms to one stack. This file
  # calls both stacks, from separate functions, by design.
  alias ImagePipe.Dialect.Imgproxy
  alias ImagePipe.Dialect.Native
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.DeclarativeFixtureDialect
  alias Vix.Vips.Image, as: VipsImage

  @p3_source "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"

  defmodule WideGamutOrigin do
    @moduledoc false

    @path "test/support/image_pipe/test/imgproxy_differential/sources/icc_p3.png"

    def init(opts), do: opts

    def call(conn, _opts) do
      conn
      |> Plug.Conn.put_resp_content_type("image/png")
      |> Plug.Conn.send_resp(200, File.read!(@path))
    end
  end

  defp sources do
    [
      path:
        {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: WideGamutOrigin]}
    ]
  end

  defp dialect_imgproxy(path) do
    ImagePipe.Plug.call(
      conn(:get, path),
      ImagePipe.Plug.init(dialect: Imgproxy, sources: sources())
    )
  end

  defp dialect_native(path) do
    ImagePipe.Plug.call(
      conn(:get, path),
      ImagePipe.Plug.init(dialect: Native, sources: sources())
    )
  end

  defp dialect_declarative(path) do
    ImagePipe.Plug.call(
      conn(:get, path),
      ImagePipe.Plug.init(dialect: DeclarativeFixtureDialect, sources: sources())
    )
  end

  # A coarse pixel grid over the fixture's distinct regions (red field, white
  # corner, green/blue cross-lines), in FRACTIONS of the output extent so the
  # same grid works for a resized arm. Sampling beats a byte compare: it survives
  # encoder nondeterminism while still catching a colorspace error, which shifts
  # every channel of every region.
  @sample_fractions for fx <- [0.01, 0.25, 0.5, 0.75, 0.99],
                        fy <- [0.01, 0.25, 0.5, 0.75, 0.99],
                        do: {fx, fy}

  defp pixels(%Plug.Conn{status: 200} = conn) do
    image = Image.open!(conn.resp_body, access: :random, fail_on: :error)
    width = Image.width(image)
    height = Image.height(image)

    Map.new(@sample_fractions, fn {fx, fy} ->
      x = min(trunc(fx * width), width - 1)
      y = min(trunc(fy * height), height - 1)
      {:ok, pixel} = Image.get_pixel(image, x, y)
      {{fx, fy}, pixel}
    end)
  end

  # The largest per-channel difference across the grid, plus the worst point —
  # so a failure reports the actual divergence, not just "not equal".
  defp max_channel_delta(a, b) do
    @sample_fractions
    |> Enum.map(fn point ->
      delta =
        [Map.fetch!(a, point), Map.fetch!(b, point)]
        |> Enum.zip_reduce(0, fn [l, r], acc -> max(acc, abs(l - r)) end)

      {delta, point, Map.fetch!(a, point), Map.fetch!(b, point)}
    end)
    |> Enum.max_by(fn {delta, _point, _a, _b} -> delta end)
  end

  defp assert_pixel_parity(oracle_conn, subject_conn) do
    assert oracle_conn.status == 200
    assert subject_conn.status == 200

    {delta, point, oracle_pixel, subject_pixel} =
      max_channel_delta(pixels(oracle_conn), pixels(subject_conn))

    assert delta == 0,
           """
           subject pixels diverge from the oracle arm (max channel delta #{delta} at #{inspect(point)})
             oracle:  #{inspect(oracle_pixel)}
             subject: #{inspect(subject_pixel)}
           """
  end

  test "the wide-gamut fixture really does carry an importable embedded profile" do
    # Positive control. If the fixture ever loses its profile, no import runs,
    # the carry is moot, and every parity assertion below passes vacuously.
    image = Image.open!(@p3_source, access: :random)

    assert {:ok, profile} = VipsImage.header_value(image, "icc-profile-data")
    assert is_binary(profile) and byte_size(profile) > 0
  end

  describe "native dialect" do
    # The oracle is the imgproxy dialect arm asked for the SAME thing: this
    # source, no geometry, PNG out, default (strip) color policy. Both dialects
    # share Decode/Transform/Output, so the only thing that can separate them
    # here is the carry.
    test "no geometry, PNG out: pixels match the imgproxy dialect's equivalent request" do
      assert_pixel_parity(
        dialect_imgproxy("/_/f:png/plain/images/icc_p3.png"),
        dialect_native("/format=png/src/images/icc_p3.png")
      )
    end
  end

  describe "declarative tier" do
    # The declarative base runs the colour preamble through
    # `Transform.Executor`'s `seed_input_color_management` gate and stamps the
    # carry itself in `ImagePipe.Dialect.Declarative.execute/4`. Both halves of
    # that seam are invisible to a header assertion, so the subject is compared
    # against an ORDERED leg (never another declarative one) asked for the same
    # bytes: this source, no geometry, PNG out, default (strip) colour policy.
    test "no geometry, PNG out: pixels match the imgproxy dialect's equivalent request" do
      assert_pixel_parity(
        dialect_imgproxy("/_/f:png/plain/images/icc_p3.png"),
        dialect_declarative("/images/icc_p3.png?f=png")
      )
    end
  end
end
