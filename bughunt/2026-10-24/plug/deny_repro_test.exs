defmodule ZzBughuntPlugETest do
  use ExUnit.Case, async: true
  import Plug.Conn
  import Plug.Test
  alias ImagePipe.SourceTest.RootHTTPAdapter
  alias ImagePipe.Test.PlugFixture.OriginImage

  @dir "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/plug/files"

  defp req(path, resp_headers, config) do
    c = conn(:get, path)
    c = Enum.reduce(resp_headers, c, fn {k, v}, c -> put_resp_header(c, k, v) end)
    ImagePipe.Plug.call(c, config)
  end

  defp show(label, c) do
    IO.puts("\n== #{label}: #{c.status}")
    IO.inspect(Enum.filter(c.resp_headers, fn {k, _} -> k in ~w(cache-control etag set-cookie vary) end))
  end

  test "deny" do
    http = [path: [adapter: RootHTTPAdapter, match: :path,
      options: [root_url: "http://origin.test", byte_identity: :strong, req_options: [plug: OriginImage], cache_policy: [storage: :deny]]]]
    file = [files: [adapter: ImagePipe.Source.File, match: :path, options: [root: @dir, root_id: "x", cache_policy: [storage: :deny]]]]
    real = fn policy -> [h: [adapter: ImagePipe.Source.HTTP, match: [scheme: ["https"]],
      options: [allowed_hosts: ["origin.test"], address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
        req_options: [plug: OriginImage], cache_policy: policy]]] end
    fileoff = [files: [adapter: ImagePipe.Source.File, match: :path, options: [root: @dir, root_id: "x", stable: :immutable, cache_policy: [storage: :deny]]]]
    for {name, sources} <- [fileoff: fileoff, http: http, file: file, real_deny: real.([storage: :deny]), real_default: real.([])] do
      config = ImagePipe.Plug.init(allow_unsigned: true, sources: sources, http_cache: :auto)
      show("#{name} plain", req(if(name in [:real_deny, :real_default], do: "/w=64/src/https%3A%2F%2Forigin.test%2Fcat.jpg", else: "/w=64/src/cat.jpg"), [], config))
      show("#{name} host cc", req(if(name in [:real_deny, :real_default], do: "/w=64/src/https%3A%2F%2Forigin.test%2Fcat.jpg", else: "/w=64/src/cat.jpg"), [{"cache-control", "public, max-age=3600"}], config))
      show("#{name} set-cookie", req(if(name in [:real_deny, :real_default], do: "/w=64/src/https%3A%2F%2Forigin.test%2Fcat.jpg", else: "/w=64/src/cat.jpg"), [{"set-cookie", "a=b"}, {"cache-control", "public, max-age=3600"}], config))
      show("#{name} set-cookie only", req(if(name in [:real_deny, :real_default], do: "/w=64/src/https%3A%2F%2Forigin.test%2Fcat.jpg", else: "/w=64/src/cat.jpg"), [{"set-cookie", "a=b"}], config))
    end
  end
end
