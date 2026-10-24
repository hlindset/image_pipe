d = "/tmp/claude-0/-home-user-image-pipe/d50ad5e9-8a8c-51d3-9791-b10ebb68545c/scratchpad/docs_server"
p = fn l, f -> r = try do f.() rescue e -> {:raised, e.__struct__, Exception.message(e)} end; IO.puts("#{l}: #{inspect(r, limit: 12, printable_limit: 300) |> String.slice(0, 400)}") end
alias ImagePipe.Source.File, as: F; alias ImagePipe.Source.HTTP, as: H
cfg = fn s -> c = ImagePipe.config(sources: s); Keyword.get(c.options, :sources) end
p.("file rel root", fn -> File.cd!(d); r = cfg.([m: [adapter: F, match: :path, options: [root: "imgs", root_id: "m"]]]); r.sources end)
p.("same root_id diff root", fn -> cfg.([a: [adapter: F, match: [prefix: "a"], options: [root: d <> "/imgs", root_id: "x"]], b: [adapter: F, match: [prefix: "b"], options: [root: d <> "/imgs/trips", root_id: "x"]]]) |> then(fn _ -> :accepted end) end)
p.("doc example web", fn -> cfg.([media: [adapter: F, match: [prefix: "media"], options: [root: d, root_id: "media"]], web: [adapter: H, match: [scheme: ["http", "https"]], options: [allowed_hosts: ["assets.example.com"]]]]) |> then(fn _ -> :ok end) end)
p.("base_url + mismatched list", fn -> cfg.([w: [adapter: H, match: [prefix: "w"], options: [base_url: "https://a.com", allowed_hosts: ["b.com"]]]]) end)
p.("base_url port in list w/o port", fn -> cfg.([w: [adapter: H, match: [prefix: "w"], options: [base_url: "https://a.com:8443", allowed_hosts: ["a.com"]]]]) end)
p.("req adapter", fn -> cfg.([w: [adapter: H, match: [scheme: "https"], options: [allowed_hosts: ["a.com"], req_options: [adapter: &Function.identity/1]]]]) end)
p.("req unix", fn -> cfg.([w: [adapter: H, match: [scheme: "https"], options: [allowed_hosts: ["a.com"], req_options: [unix_socket: "/x"]]]]) end)
p.("immutable freshness", fn -> cfg.([m: [adapter: F, match: :path, options: [root: d, root_id: "m", stable: :immutable, cache_policy: [freshness: {:fallback, 60}]]]]) end)
p.("immutable swr", fn -> cfg.([m: [adapter: F, match: :path, options: [root: d, root_id: "m", stable: :immutable, cache_policy: [stale_while_revalidate: {:force, 60}]]]]) end)
p.("immutable freshness origin", fn -> cfg.([m: [adapter: F, match: :path, options: [root: d, root_id: "m", stable: :immutable, cache_policy: [freshness: :origin]]]]) |> then(fn _ -> :accepted end) end)
p.("missing root", fn -> cfg.([m: [adapter: F, match: :path, options: [root: d <> "/nope", root_id: "m"]]]) |> then(fn _ -> :accepted end) end)
p.("http no hosts no base", fn -> cfg.([w: [adapter: H, match: [scheme: "https"], options: []]]) end)
