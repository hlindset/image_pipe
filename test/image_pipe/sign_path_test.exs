defmodule ImagePipe.SignPathTest do
  use ExUnit.Case, async: true

  @key Base.encode16(:binary.copy(<<71>>, 32))
  @previous_key Base.encode16(:binary.copy(<<72>>, 32))

  test "signs exact path bytes with the first decoded key, ignoring URL defaults" do
    config = ImagePipe.config(keys: [@key, @previous_key], base_url: "/artwork")

    for path <- ["/w=%33%30/src/photo%2ejpg", "/src/a//b", "/src/a%3Fb%23c"] do
      signature =
        :crypto.mac(:hmac, :sha256, Base.decode16!(@key), path)
        |> Base.url_encode64(padding: false)

      assert ImagePipe.sign_path(path, config) == "/sig=#{signature}#{path}"
    end
  end

  test "requires signing keys" do
    assert_raise ArgumentError, fn ->
      ImagePipe.sign_path("/src/photo.jpg", ImagePipe.config())
    end
  end

  test "requires an unsigned mount-relative path without query or fragment" do
    config = ImagePipe.config(keys: [@key])

    for path <- [
          "src/photo.jpg",
          "",
          "/src/photo.jpg?q=1",
          "/src/photo.jpg#x",
          "/sig=existing/src/photo.jpg",
          "https://cdn.test/src/photo.jpg"
        ] do
      assert_raise ArgumentError, fn -> ImagePipe.sign_path(path, config) end
    end
  end
end
