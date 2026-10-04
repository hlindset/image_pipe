# Performance: sources and caching

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:31:34Z

Performance: sources and caching

## Claude · 2026-10-04T11:36:30Z

I found four changes in sources and caching that look large, plus about a dozen smaller ones. I worked these out by reading the code; nothing was benchmarked, because Elixir isn't installed here. I re-checked the top items in the code myself.

1. **Admission scans grow with cache size.** Every cache hit scans whole ETS tables inside the single Admission process, because lookups by hash use `match_object` with the first key element unbound (`cache/file_system/admission.ex:846`). With about 100k entries this can back up the mailbox until commits time out and writes are dropped. A hash index fixes it. Startup has the same problem and runs O(N²).
2. **Local files rewrite a cache entry on every request.** The default `verify: :stat` revalidates each time, and a `:not_modified` result still writes a full output-pool entry and makes an Admission call (`execution/source_cache.ex:146-150`). Concurrent requests for one popular file then do this one at a time under the per-key lock.
3. **Cache hits read the body twice.** Each hit SHA-256-hashes the whole body, then reads it again to send it through the BEAM (`cache/file.ex:10-36`). Verifying once at write time and serving hits with `send_file` would remove a full pass per hit. Input-cache hits re-hash the whole original too.
4. **S3 credential rotation clears the cache.** Rotating S3 credentials are digested into both the cache key and the ETag (`source/s3.ex:281-286`), so each roughly hourly rotation invalidates every cached result for that bucket and makes clients download everything again. The code comment suggests this is intentional, so it's your call.

Other findings include serial, uncached DNS lookups on every fetch, a Req/Finch pool start-up call on every request, pools keyed by pinned IP that never expire, and a per-bucket credential GenServer read even on cache hits. They're in the write-up with `file:line` for each: [sources-and-caching.md](/mnt/project-files/perf-review/sources-and-caching.md)

I haven't changed any code. Tell me which items you'd like fixed. My suggestion is to start with 1 and 2, and to write a small benchmark first so we can measure the gain.
