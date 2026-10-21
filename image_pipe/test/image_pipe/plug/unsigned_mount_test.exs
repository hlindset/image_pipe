defmodule ImagePipe.Plug.UnsignedMountTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog
  import Plug.Test

  @key String.duplicate("a1", 32)
  @sources [
    path: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [
        root: Path.expand("../../support/image_pipe/test/sources", __DIR__),
        root_id: "unsigned-mount"
      ]
    ]
  ]

  test "a mount without keys raises on a request unless it allows unsigned URLs" do
    mount = ImagePipe.Plug.init(sources: @sources)

    error = assert_raise ArgumentError, fn -> request(mount) end
    assert error.message =~ ":keys"
    assert error.message =~ "allow_unsigned: true"

    assert request(ImagePipe.Plug.init(sources: @sources, allow_unsigned: true)).status == 200
  end

  test "a mount with keys checks signatures without allow_unsigned" do
    assert request(ImagePipe.Plug.init(sources: @sources, keys: [@key])).status == 403
  end

  test "an instance mount follows the instance's setting" do
    start_supervised!({ImagePipe, name: __MODULE__.Unsigned, sources: @sources})

    start_supervised!(
      {ImagePipe, name: __MODULE__.Allowed, sources: @sources, allow_unsigned: true}
    )

    assert_raise ArgumentError, ~r/allow_unsigned: true/, fn ->
      request(ImagePipe.Plug.init(instance: __MODULE__.Unsigned))
    end

    assert request(ImagePipe.Plug.init(instance: __MODULE__.Allowed)).status == 200
  end

  test "an instance that allows unsigned URLs warns once when it starts" do
    log =
      capture_log(fn ->
        start_supervised!(
          {ImagePipe, name: __MODULE__.Warns, sources: @sources, allow_unsigned: true}
        )
      end)

    assert log =~ "#{inspect(__MODULE__.Warns)} serves unsigned URLs"
    assert log =~ "private network"

    log =
      capture_log(fn ->
        start_supervised!(
          {ImagePipe,
           name: __MODULE__.Signed, sources: @sources, keys: [@key], allow_unsigned: true}
        )
      end)

    refute log =~ inspect(__MODULE__.Signed)
  end

  defp request(mount), do: ImagePipe.Plug.call(conn(:get, "/w=8/src/alpha.png"), mount)
end
