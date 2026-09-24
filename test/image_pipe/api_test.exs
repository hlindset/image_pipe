defmodule ImagePipe.APITest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Security.Signature
  alias ImagePipe.SourceTest.RootHTTPAdapter

  describe "init/1" do
    test "returns validated config for an empty option list" do
      opts = ImagePipe.Plug.init([])

      assert Signature.verify(nil, "/src/a.jpg", opts) == {:ok, nil}
      assert Keyword.fetch!(opts, :presets) == %{}
      assert Keyword.fetch!(opts, :storage_inputs) == []
      assert Keyword.fetch!(opts, :max_body_bytes) == 10_000_000
      assert Keyword.fetch!(opts, :max_input_pixels) == 40_000_000
    end

    test "raises on an unknown option" do
      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(bogus_option: true)
      end
    end

    test "raises on a non-hex key" do
      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(keys: ["not-hex"])
      end
    end

    test "accepts valid hex keys" do
      opts = ImagePipe.Plug.init(keys: ["deadbeef"])

      signature = Signature.sign("/src/a.jpg", opts)
      assert Signature.verify(signature, "/src/a.jpg", opts) == {:ok, 0}
      refute inspect(opts) =~ "deadbeef"
    end

    test "compiles preset options at initialization" do
      opts = ImagePipe.Plug.init(presets: %{"card" => "w=300/h=200/fit=cover"})

      assert Keyword.fetch!(opts, :presets) == %{
               "card" => %{
                 groups: %{0 => %{width: 300, height: 200, fit: :cover}},
                 request: %{}
               }
             }
    end

    test "raises on a preset fragment with an unknown option" do
      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(presets: %{"bad" => "bogus=1"})
      end
    end

    test "raises on a presets value that is not a map of strings" do
      assert_raise ArgumentError, fn ->
        ImagePipe.Plug.init(presets: %{"bad" => 123})
      end
    end
  end

  describe "complete-body response headers" do
    test "BlurHash includes Vary for configured storage-header identity" do
      body = 16 |> Image.new!(12, color: [90, 100, 110]) |> Image.write!(:memory, suffix: ".jpg")

      origin = fn conn ->
        conn
        |> put_resp_content_type("image/jpeg")
        |> send_resp(200, body)
      end

      config =
        ImagePipe.Plug.init(
          sources: [
            path:
              {RootHTTPAdapter,
               root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: origin]}
          ],
          storage_inputs: [{:header, "X-Tenant"}]
        )

      conn =
        :get
        |> conn("/output=blurhash/src/images/cat.jpg")
        |> put_req_header("x-tenant", "acme")
        |> ImagePipe.Plug.call(config)

      assert conn.status == 200
      assert get_resp_header(conn, "vary") == ["x-tenant"]
    end
  end

  # call/2's real request chain (parse → source → negotiate → serve) is
  # exercised end-to-end in test/image_pipe/api_wire_test.exs.
end
