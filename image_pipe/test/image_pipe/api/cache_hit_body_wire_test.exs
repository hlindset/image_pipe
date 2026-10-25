defmodule ImagePipe.API.CacheHitBodyWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.FileSystem.Admission
  alias ImagePipe.Cache.FileSystem.Store
  alias ImagePipe.Test.Caches

  @path "/w=12/format=png/src/beach.jpg"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "image-pipe-cache-hit-body-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf!(root) end)
    sources = Path.join(root, "sources")
    File.mkdir_p!(sources)
    File.cp!("priv/static/images/beach.jpg", Path.join(sources, "beach.jpg"))
    cache_root = Path.join(root, "output")

    opts =
      Caches.start!(
        sources: [
          path: [
            adapter: ImagePipe.Source.File,
            match: :path,
            options: [root: sources, root_id: "hit-body"]
          ]
        ],
        cache: [root: cache_root, max_size_bytes: 50_000_000]
      )

    [{pid, _value}] = Registry.lookup(Store.registry_name(cache_root), cache_root)
    :ok = Admission.await_scan(pid)
    %{opts: opts, cache_root: cache_root}
  end

  # The third request reads the entry from memory, so it has no descriptor
  # open on the body when it's deleted.
  test "a remembered entry whose body is deleted is generated again", ctx do
    first = request(:get, ctx.opts)
    assert first.status == 200
    assert request(:get, ctx.opts).resp_body == first.resp_body
    assert request(:get, ctx.opts).resp_body == first.resp_body

    delete_bodies(ctx.cache_root)

    again = request(:get, ctx.opts)
    assert again.status == 200
    assert again.resp_body == first.resp_body
    assert bodies(ctx.cache_root) != []
    assert request(:get, ctx.opts).resp_body == first.resp_body
  end

  test "a HEAD for a remembered entry reports the body's length", ctx do
    first = request(:get, ctx.opts)
    _hit = request(:get, ctx.opts)

    head = request(:head, ctx.opts)
    assert head.status == 200
    assert head.resp_body == ""

    assert get_resp_header(head, "content-length") == [
             Integer.to_string(byte_size(first.resp_body))
           ]
  end

  defp request(method, opts) do
    response = ImagePipe.Plug.call(conn(method, @path), Caches.plug(opts))
    Caches.await_writes(opts)
    response
  end

  defp bodies(cache_root), do: Path.wildcard(Path.join(cache_root, "**/*.body"))
  defp delete_bodies(cache_root), do: Enum.each(bodies(cache_root), &File.rm!/1)
end
