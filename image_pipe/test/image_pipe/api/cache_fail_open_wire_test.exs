defmodule ImagePipe.API.CacheFailOpenWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.FileSystem
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.CacheObserver

  @moduletag capture_log: true

  for {label, content_type, representation} <- [
        {"mismatched terminal", "text/plain", {:complete_body, "text/html"}},
        {"invalid terminal tag", "text/plain", {:complete_body, nil}},
        {"unsupported terminal type", "text/html", {:complete_body, "text/html"}},
        {"wrong terminal type", "text/plain", {:complete_body, "text/plain"}},
        {"control characters", "text/plain;\rcharset=utf-8",
         {:complete_body, "text/plain;\rcharset=utf-8"}},
        {"mismatched image", "image/png", {:image, :jpeg}},
        {"unknown tag", "image/png", {:unknown, :png}}
      ] do
    test "#{label} cache representation fails open" do
      body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".jpg")
      origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

      opts = [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              byte_identity: :strong,
              internal_cache: :enabled,
              req_options: [plug: origin]
            ]
          ]
        ]
      ]

      path = "/output=info/src/source.jpg"
      baseline = ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(opts))

      cached_opts = CacheObserver.observe(opts)
      config = ImagePipe.Plug.init(cached_opts)
      _stored = ImagePipe.Plug.call(conn(:get, path), config)
      assert_received {:cache_put, hash, _body}
      CacheObserver.lookup_hashes()

      {:ok, %{meta_path: meta_path}} =
        FileSystem.paths_from_hash(hash, Keyword.fetch!(cached_opts, :cache))

      metadata = meta_path |> File.read!() |> :erlang.binary_to_term()

      corrupt = %{
        metadata
        | content_type: unquote(content_type),
          representation: unquote(Macro.escape(representation))
      }

      File.write!(meta_path, :erlang.term_to_binary(corrupt))

      response = ImagePipe.Plug.call(conn(:get, path), config)

      assert response.status == 200
      assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
      assert response.resp_body == baseline.resp_body
      assert hash in CacheObserver.lookup_hashes()
      assert_received {:cache_put, ^hash, _body}
    end
  end

  for {output, content_type} <- [
        {"w=12/format=png", "image/png"},
        {"output=info", "application/json; charset=utf-8"}
      ] do
    test "#{output} is delivered when the cache can't open an entry" do
      body = Image.new!(24, 16, color: :red) |> Image.write!(:memory, suffix: ".jpg")
      origin = fn conn -> conn |> put_resp_content_type("image/jpeg") |> send_resp(200, body) end

      opts = [
        sources: [
          path: [
            adapter: RootHTTPAdapter,
            match: :path,
            options: [
              root_url: "http://origin.test",
              byte_identity: :strong,
              internal_cache: :enabled,
              req_options: [plug: origin]
            ]
          ]
        ]
      ]

      path = "/#{unquote(output)}/src/source.jpg"
      baseline = ImagePipe.Plug.call(conn(:get, path), ImagePipe.Plug.init(opts))

      cached_opts = CacheObserver.observe(opts)
      root = cached_opts |> Keyword.fetch!(:cache) |> Keyword.fetch!(:root)
      config = ImagePipe.Plug.init(cached_opts)
      File.chmod!(root, 0o500)
      on_exit(fn -> File.chmod(root, 0o700) end)

      response = ImagePipe.Plug.call(conn(:get, path), config)

      assert [_hash | _] = CacheObserver.lookup_hashes()
      assert baseline.status == 200
      assert response.status == 200
      assert get_resp_header(response, "content-type") == [unquote(content_type)]
      assert response.resp_body == baseline.resp_body
      refute_received {:cache_put, _hash, _body}
    end
  end
end
