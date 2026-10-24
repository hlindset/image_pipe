defmodule ZZDocsDelivATest do
  use ExUnit.Case, async: false
  import Plug.Conn
  import Plug.Test
  alias ImagePipe.Test.Caches

  setup do
    root = Path.join(System.tmp_dir!(), "zzdd-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "files"))
    File.cp!("priv/static/images/beach.jpg", Path.join(root, "files/beach.jpg"))
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, agent} = Agent.start_link(fn -> %{cc: "public, max-age=3600", extra: []} end)
    body = File.read!("priv/static/images/beach.jpg")
    origin = fn conn ->
      st = Agent.get(agent, & &1)
      conn = Enum.reduce([{"cache-control", st.cc} | st.extra], conn, fn {k, v}, c -> put_resp_header(c, k, v) end)
      conn |> put_resp_header("etag", ~s("o1")) |> put_resp_content_type("image/jpeg") |> send_resp(200, body)
    end
    %{root: root, agent: agent, origin: origin}
  end

  def fwd(event, meas, meta, pid), do: send(pid, {:tel, event, meas, meta})

  defp start(ctx, overrides \\ []) do
    {http_opts, overrides} = Keyword.pop(overrides, :http_opts, [])
    {file_opts, overrides} = Keyword.pop(overrides, :file_opts, [])
    prefix = [:zzdd, :"p#{System.unique_integer([:positive])}"]
    opts = [
      sources: [
        url: [adapter: ImagePipe.Source.HTTP, match: [scheme: ["http", "https"]],
          options: [allowed_hosts: ["origin.test"], address_resolver: fn _ -> {:ok, [{93, 184, 216, 34}]} end,
            req_options: [plug: ctx.origin]] ++ http_opts],
        media: [adapter: ImagePipe.Source.File, match: [prefix: "media"],
          options: [root: Path.join(ctx.root, "files"), root_id: "m"] ++ file_opts]
      ],
      telemetry_prefix: prefix,
      cache: [root: Path.join(ctx.root, "out#{System.unique_integer([:positive])}")]
    ] |> Keyword.merge(overrides)
    opts = Caches.start!(opts)
    for ev <- [[:http_cache, :prepare], [:http_cache, :cache_hit, :headers], [:http_cache, :fallback, :no_store]] do
      id = make_ref()
      :telemetry.attach(id, prefix ++ ev, &__MODULE__.fwd/4, self())
      on_exit(fn -> :telemetry.detach(id) end)
    end
    opts
  end

  defp req(opts, path, fun \\ & &1, method \\ :get) do
    c = conn(method, path) |> fun.() |> ImagePipe.Plug.call(Caches.plug(opts))
    Caches.await_writes(opts)
    c
  end

  defp show(label, c) do
    IO.puts("#{label}: #{c.status} cc=#{inspect get_resp_header(c, "cache-control")} etag=#{inspect get_resp_header(c, "etag")} age=#{inspect get_resp_header(c, "age")} vary=#{inspect get_resp_header(c, "vary")}")
    tels = collect([])
    for {e, _m, meta} <- tels, do: IO.puts("   tel #{inspect List.last(e, nil) && Enum.take(e, -2)} #{inspect meta}")
    c
  end
  defp collect(acc) do
    receive do
      {:tel, e, m, meta} -> collect(acc ++ [{e, m, meta}])
    after 0 -> acc
    end
  end

  @u "/w=20/format=png/src/https://origin.test/a.jpg"

  test "probe http", ctx do
    o = start(ctx, http_cache: :auto)
    show("auto max-age=3600", req(o, @u))
    show("auto max-age=3600 HIT", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "private, max-age=3600"})
    o = start(ctx, http_cache: :auto)
    show("auto private", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "no-store"})
    o = start(ctx, http_cache: :auto)
    show("auto no-store", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "no-cache"})
    o = start(ctx, http_cache: :auto)
    show("auto no-cache", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "max-age=100, s-maxage=50"})
    o = start(ctx, http_cache: :auto)
    show("auto s-maxage", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "max-age=100, stale-while-revalidate=30"})
    o = start(ctx, http_cache: :auto)
    show("auto swr", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "max-age=100, must-revalidate"})
    o = start(ctx, http_cache: :auto, http_opts: [cache_policy: [stale_while_revalidate: {:force, 20}]])
    show("auto must-reval forced swr", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "max-age=100", extra: [{"vary", "*"}]})
    o = start(ctx, http_cache: :auto, http_opts: [cache_policy: [storage: :allow]])
    show("auto vary* allow", req(o, @u))
    Agent.update(ctx.agent, &%{&1 | cc: "max-age=100", extra: []})
    o = start(ctx, http_cache: :validators)
    show("validators max-age=100", req(o, @u))
    show("validators HIT", req(o, @u))
    o = start(ctx, http_cache: :auto)
    show("host cc", req(o, @u, &put_resp_header(&1, "cache-control", "public, max-age=10")))
    show("host etag", req(o, @u, &put_resp_header(&1, "etag", ~s("host"))))
    c = show("host etag again inm", req(o, @u, fn c -> c |> put_resp_header("etag", ~s("host")) |> put_req_header("if-none-match", ~s("host")) end))
    _ = c
    show("expires", req(o, "/expires=#{System.os_time(:second) + 100}" <> @u))
    show("expires host cc", req(o, "/expires=#{System.os_time(:second) + 100}" <> @u, &put_resp_header(&1, "cache-control", "public, max-age=86400.5, s-maxage=99999, stale-if-error=5")))
    show("head", req(o, @u, & &1, :head))
    show("options", req(o, @u, & &1, :options))
    show("post", req(o, @u, & &1, :post))
    show("inm * miss", req(o, "/w=21/format=png/src/https://origin.test/a.jpg", &put_req_header(&1, "if-none-match", "*")))
    show("set-cookie", req(o, "/w=22/format=png/src/https://origin.test/a.jpg", &put_resp_cookie(&1, "a", "b")))
    show("automatic vary", req(o, "/w=22/src/https://origin.test/a.jpg", &put_req_header(&1, "accept", "image/webp")))
  end

  test "probe file", ctx do
    o = start(ctx, http_cache: :auto)
    show("file changeable", req(o, "/w=20/format=png/src/media/beach.jpg"))
    o = start(ctx, http_cache: :validators)
    show("file changeable validators", req(o, "/w=20/format=png/src/media/beach.jpg"))
    o = start(ctx, http_cache: :validators, file_opts: [stable: :immutable])
    show("file immutable validators", req(o, "/w=20/format=png/src/media/beach.jpg"))
    show("file immutable validators HIT", req(o, "/w=20/format=png/src/media/beach.jpg"))
    show("file immutable validators exp", req(o, "/expires=#{System.os_time(:second) + 100}/w=20/format=png/src/media/beach.jpg"))
    o = start(ctx, http_cache: :auto, file_opts: [stable: :immutable, cache_policy: [storage: :deny]])
    show("file immutable deny", req(o, "/w=20/format=png/src/media/beach.jpg"))
    show("file immutable deny exp", req(o, "/expires=#{System.os_time(:second) + 100}/w=20/format=png/src/media/beach.jpg"))
    o = start(ctx, http_cache: :auto, file_opts: [cache_policy: [freshness: {:fallback, 3600}], http_cache: :private])
    show("file fallback private", req(o, "/w=20/format=png/src/media/beach.jpg"))
    show("missing", req(o, "/expires=#{System.os_time(:second) + 100}/w=20/format=png/src/media/nope.jpg", &put_resp_header(&1, "cache-control", "public, max-age=999")))
    show("parse err", req(o, "/expires=#{System.os_time(:second) + 100}/zz=20/format=png/src/media/nope.jpg", &put_resp_header(&1, "cache-control", "public, max-age=999")))
    r = (try do start(ctx, file_opts: [stable: :immutable, cache_policy: [freshness: {:fallback, 3600}]]); :started rescue e -> {:raised, Exception.message(e)} catch k, v -> {k, v} end)
    IO.puts("immutable+fallback: #{inspect r}")
  end
end
