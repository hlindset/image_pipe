# Speed up sources and caching

User-visible conversation from the ImagePipe project thread, exported 2026-10-04. Status updates and tool activity are omitted.

## Claude · 2026-10-04T11:44:40Z

Speed up sources and caching

## Claude · 2026-10-04T11:47:29Z

The cloud setup failed again, though Erlang and Elixir did install. `mise install` stops on the other tools in `mise.toml` (uv, pnpm, python, rust, shot-scraper): their version lookups go to `mise-versions.jdx.dev`, which the network policy blocks, and then fall back to GitHub's API, which hit the anonymous rate limit. Because `mise install` fails, `mise run setup` never reaches `mix deps.get`, and `mise exec` retries the install and fails the same way.

Two ways to fix it: allow `mise-versions.jdx.dev` in the environment's network settings (plus a `GITHUB_TOKEN` secret for the GitHub fallback), or have the SessionStart hook install only `erlang elixir` when it runs in the cloud. I'm working around it here by calling Erlang and Elixir directly, and `mix deps.get` works that way.

## Håvard · 2026-10-04T12:09:08Z

the context for choosing is a bit lacking

## Håvard · 2026-10-04T12:11:14Z

can you explain the choice I made there vs the other? (Sendfile)

## Claude · 2026-10-04T12:16:55Z

Fair point, the card left out too much. Here's the trade-off.

**What a cache hit did before:** it read the whole cached file and computed its SHA-256 to confirm the file hadn't changed on disk. Then it read the file a second time and sent it through the BEAM in 64 KB chunks. A 1 MB hit meant two full reads and a hash on every request.

**Size check + sendfile (your pick):** a hit only checks that the file's size matches the size recorded when it was written. That still catches truncated files. The body then goes out with `Plug.Conn.send_file`, so the kernel copies it straight from disk to the socket and the BEAM never touches the bytes. A 1 MB hit dropped from 4.8 to 3.3 ms over Bandit. The cost: if a file were corrupted on disk without changing size, the corrupted bytes would be served. Bodies are hashed when written and never edited in place, so that would take disk-level damage or someone editing the cache directory by hand.

**Hash while streaming:** this keeps the corruption check and needs only one read, but it can't use sendfile because the BEAM has to see every byte. The hash only finishes after the headers and most of the body have gone out, so a corrupt file shows up as a dropped connection rather than a regenerated image.

There's one gap in what's committed. The size check runs on the open file, but `send_file` reopens it by path. A file swapped between the two would be sent unchecked. Sending from the already-open file would close that.

I've stopped as the coordinator asked. Everything is committed locally on `claude/project-thread-8jzkwh` in 8 commits, not pushed:
- **Admission lookups:** cache hits at 10k entries went from 788 to 71 µs.
- **Local-file revalidation:** a hit no longer rewrites a cache entry on every request, so a warm hit went from 2.3 to 1.5 ms.
- **Cache hits:** size check and sendfile, as above.
- **Smaller wins:** cache options are no longer revalidated on every lookup, Finch pools start once (a fetch went from 341 to 209 µs), the IPv4 and IPv6 DNS lookups run in parallel, and the local-file readability check opens the file raw.

**Not done:**
- The precommit gate never finished. Targeted tests pass except about 15 that also fail on `main` in this container (running as root, no IPv6, no JPEG XL).
- I couldn't measure the DNS change here.
- The cache docs wording needs a tightening pass.
- I skipped the S3 credentials cache, the double write of copied originals, and the smaller spool writes.

## Claude · 2026-10-04T14:16:51Z

I pushed `claude/project-thread-8jzkwh` with all 8 commits and no open PR. There was no uncommitted work to add.

**Done:**
- Indexed admission lookups.
- Local-file sources no longer rewrite their cache record on every request.
- Cache hits check only the file size and go out with sendfile.
- Cache options are no longer re-validated on every path lookup.
- Each Finch connection pool starts once instead of per fetch.
- IPv4 and IPv6 DNS lookups run in parallel.
- The local-file readability check opens the file raw.
- Docs updated for the size-only check.

**Unfinished:**
- The full precommit never finished, so dialyzer and credo haven't run over all of it.
- The cache docs wording needs a fix from the review. It doesn't say that swapping or replacing a cached file also matters.
- Code gap: a hit checks the size on the file it opened but sends by path, so a file replaced between the two is sent unchecked.
- The DNS change is unmeasured.
- Skipped: the S3 credentials cache, the double write of copied originals, and buffering spool writes.
