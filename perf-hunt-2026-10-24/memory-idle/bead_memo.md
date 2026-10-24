What: the output cache's Memo (image_pipe/lib/image_pipe/cache/file_system/memo.ex, filled from store.ex:409-416 `Memo.remember(paths.root, paths.hash, epoch, {entry, hit})`) keeps every recently hit entry's full `%ImagePipe.Cache.Entry{}` in ETS, including its `debug: %ImagePipe.Debug.Info{}` (23 fields plus a timings map). That struct is only read on a hit when the request asked for debug headers (response/sender.ex:84-97 `hit_debug_headers`, guarded by `opts[:debug?]`), so for ordinary traffic it's dead weight that stays in memory for as long as the row does. The table holds up to `max_remembered_entries` rows (default one per 50 KB of `max_size_bytes`, 1,000-50,000), so it is part of what an idle server keeps after traffic.

Measured (local prod release of image_pipe_server, `[cache.output] max_size_bytes = 10_000_000_000`, so the cap is 50,000 rows; two rounds of 637 varied requests filled 624 memo rows; then copied the rows into a scratch ETS table with the same options to compare shapes):

| row shape | ETS bytes per row |
|---|---|
| as stored (Entry with Debug.Info) | 1,396 |
| `debug: nil` | 847 |
| debug as `term_to_binary` | 911 |

Debug.Info alone is 549 B of flat term per row (39%). At the 50,000-row cap that is ~70 MB of memo vs ~42 MB without it: ~27 MB of idle memory saved on a server with a 10 GB cache (~11 MB for 1 GB, ~0.5 MB at the 1,000-row minimum).

Repro (rpc into a warmed server):
```elixir
[t] = for t <- :ets.all(), is_atom(t), String.contains?(Atom.to_string(t), "Memo."), do: t
rows = :ets.tab2list(t)
e = :ets.new(:probe, [:public, :set, read_concurrency: true, write_concurrency: true])
for {k, {en, m}, ep} <- rows, do: :ets.insert(e, {k, {%{en | debug: nil}, m}, ep})
{:ets.info(t, :memory) * 8 / length(rows), :ets.info(e, :memory) * 8 / length(rows)}
```

Proposed fix: remember the entry with `debug: nil` and let a debug request on a memo hit read the metadata from disk (treat a memo row without debug as a miss when `debug?` is set), or keep debug as a compact binary. Size: a few lines in store.ex + a test that a debug hit still renders the headers after the entry was remembered. Risk: low; debug requests on hot entries pay one metadata read. Docs in image_pipe_server/docs/server-configuration.md and image_pipe/lib/image_pipe/cache.ex quote "about 1.8 KB each" for remembered entries; update the figure.
