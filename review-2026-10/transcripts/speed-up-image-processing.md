# Speed up image processing

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:46:10Z

Speed up image processing

## Claude · 2026-10-04T12:00:46Z

Nothing needed from you yet beyond the effort card above.

The cloud setup partly failed again. Erlang, Elixir and Node installed, but `mise install` couldn't get pnpm, Python, uv or shot-scraper, so `mise run setup` stopped and no Mix deps were fetched. Two hosts are blocked: `mise-versions.jdx.dev` (not in the network allowlist) and `api.github.com` release lookups (403). Adding `mise-versions.jdx.dev` to the environment's allowed hosts should fix most of it. I worked around it by running Mix from the installed toolchain directly, so the Elixir work and tests run fine here.

First result: the crop-mode quality search now builds its tile references once. Large `autoquality=ssimulacra2` JPEG requests got 17 to 23% faster (for example waterfall at w=3200 went from 6.1 s to 5.1 s) with byte-identical output. Committed locally. Concurrent face and object detection is done and tested, and the cache A/B is running.

## Claude · 2026-10-04T12:01:16Z

I've stopped as asked, and the finished work is committed locally on `claude/project-thread-6djvq7`. Nothing is pushed.

**Done**
- The crop-score speedup.
- Concurrent face and object detection, with tests.
- The trim design note: [trim-shrink-on-load.md](image_pipe/docs/plans/trim-shrink-on-load.md).

**Left**
- The docs note for keeping effort at 4. Your pick is noted, but I haven't written it.
- The operation-cache A/B. I stopped it before it produced results.
- A full `mise run precommit`. Only the focused tests for the changed code have run, and they pass.

## Claude · 2026-10-04T12:07:02Z

The three commits are pushed to `claude/project-thread-6djvq7` on GitHub. No PR was opened.

## Håvard · 2026-10-04T12:07:11Z

* A/B the operation cache (stopped before results)

what was this all about?

## Claude · 2026-10-04T12:07:15Z

This was item 5 of the perf review. libvips keeps a cache of recently run operations (up to 100 operations and 100 MB by default). ImagePipe never changes it, so production runs with that cache on. Every benchmark and the test suite turn it off, so the repo's latency and memory numbers don't describe what production actually does.

The review's guess is that the cache seldom helps here, because most traffic is different images and sizes. Meanwhile it keeps old intermediate image buffers in memory after their requests finish. The A/B was meant to run the same requests with the cache on and off, comparing latency and memory, and then decide between:
- having the server turn the cache off,
- recommending that in the docs,
- leaving it alone.

I stopped it before it produced numbers, so nothing has changed and nothing is decided. It's a low-priority check that mostly affects memory, not speed.
