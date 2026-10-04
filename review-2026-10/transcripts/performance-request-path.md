# Performance: request path

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:31Z

Performance: request path

## Claude · 2026-10-04T11:39:43Z

I found three changes in the request path worth making. Everything else I checked costs about a microsecond and isn't worth touching. I haven't changed any code. If you want some of these done, tell me which ones.

1. **The URL options get parsed twice.** Every request runs a full option-parsing pass just to collect preset names (`plug/request.ex:46-49`). Unless `:preset_lookup` is set, which it isn't by default, that result is thrown away and the real parse starts over. Measured on the real parser: 13–27 µs wasted out of 44–109 µs total, about 30% of parse time. The fix is a small guard.
2. **Cache hits go through the file three times.** Each hit hashes the whole cached file, reads it a second time to send it, and opens it without `:raw`. A 300 KB hit takes 593 µs; sending alone would take 81 µs, and less again with `send_file`. The sources-and-caching review found the same problem, so this should be one fix shared with that thread. I added the delivery-side measurements.
3. **Uncached responses stream in lock-step, one small chunk at a time.** The request process asks for a chunk, waits for it, writes it, then asks for the next (`delivery/producer.ex:101-120`). This one is inferred: Vix wouldn't build here, so I couldn't count chunks per response. Batching chunks to about 64 KB should cut message and socket overhead on large images.

Two smaller ones: cache headers are built twice on every 200 response, which also fires the `[:http_cache, :prepare]` telemetry event twice, and cookies are parsed on every request even though they're only read when a mount uses `storage_inputs` with cookies. Tracer overhead is about 1 µs per event, and signing and format negotiation are negligible.

These are microbenchmarks, not end-to-end timings: the container can't reach hex.pm, so I ran the real `image_pipe_url` parser with stubbed deps on Elixir 1.19 / OTP 28. The project pins Elixir 1.20 / OTP 29. The report has the tables, file:line references and suggested fixes: [request-path.md](/mnt/project-files/perf-review/request-path.md)
