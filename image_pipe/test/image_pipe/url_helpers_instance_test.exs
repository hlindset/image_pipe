defmodule ImagePipe.URL.HelpersInstanceTest do
  use ExUnit.Case, async: true

  @key "00112233445566778899aabbccddeeff"

  defmodule Page do
    use ImagePipe.URL.Helpers, instance: ImagePipe.URL.HelpersInstanceTest.Images

    def thumbnail(source), do: image_url(source, group: [resize: [width: 300]])
  end

  defmodule MountPage do
    use ImagePipe.URL.Helpers, instance: ImagePipe.URL.HelpersInstanceTest.Images, mount: :thumbs

    def thumbnail(source), do: image_url(source, group: [resize: [width: 300]])
  end

  test "builds URLs with the instance's URL settings" do
    start_supervised!(
      {ImagePipe,
       name: ImagePipe.URL.HelpersInstanceTest.Images,
       base_url: "/media",
       keys: [@key],
       mounts: [thumbs: [base_url: "/thumbs"]]}
    )

    builder = ImagePipe.URL.new(ImagePipe.url_config(ImagePipe.URL.HelpersInstanceTest.Images))

    expected =
      builder |> ImagePipe.URL.group(resize: [width: 300]) |> ImagePipe.URL.url!("cat.jpg")

    assert Page.thumbnail("cat.jpg") == expected
    assert "/media/sig=" <> _ = expected
    assert "/thumbs/sig=" <> _ = MountPage.thumbnail("cat.jpg")
  end

  test "instance: and config: can't be combined, and mount: needs instance:" do
    for options <- [
          "instance: ImagePipe.URL.HelpersInstanceTest.Images, config: {Kernel, :self, []}",
          "mount: :thumbs"
        ] do
      assert_raise ArgumentError, fn ->
        Code.compile_string("""
        defmodule ImagePipe.URL.HelpersInstanceTest.Invalid do
          use ImagePipe.URL.Helpers, #{options}
        end
        """)
      end
    end
  end
end
