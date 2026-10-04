# Bug hunt: sources and caching

Scope: `image_pipe` HTTP, S3 and file sources, network policy, source identity, caches, ETags, HTTP cache modes and staging.

**How this was checked:** static review only. Tests could not run, because the session's network policy blocks `repo.hex.pm`, so no dependencies install. I read the code for every finding below myself. Each "test" line describes an ExUnit test that should fail today; none of them has been run yet.

## Likely bugs, most important first

### 1. Rotating S3 credentials break the cache and change ETags
- `lib/image_pipe/source/s3.ex:281-285`: `prepare_cache/3` writes the provider's current temporary credentials into `fetch` as `{:static, credentials}`.
- `lib/image_pipe/source.ex:199-210`: `prepare_cache_context/2` puts `prepared.fetch` into the cache context. That context feeds the source partition (`Representation.input_key`) and, for stable S3 sources, the strong byte identity `{seed, MaterialDigest.of(context)}`.
- **Effect:** with `InstanceRole`, `WebIdentity`, `AssumeRole` or `ContainerCredentials`, each refresh (about hourly) brings a new token. Each refresh then:
  - misses every cached original and output;
  - for versioned objects, changes the ETag, so clients download identical bytes again. That breaks the AGENTS.md rule that the ETag reflects byte identity only.
- **Fix:** partition by the configured provider, or by the access key ID, rather than by the secret or session token.
- **Test:** a provider that returns token t1 and then t2. Assert that the `input_key` hash and the strong byte identity are the same before and after the refresh.

### 2. An empty S3 revision sends `?versionId=`
- `s3.ex:207` and `s3.ex:261` treat `revision: ""` as "no revision". `revision_query/1` at `s3.ex:470-473` matches only `nil`, so `""` builds `?versionId=`.
- **How to reach it:** `s3://bucket/cat.jpg%3F` decodes to a trailing `?`, and the parser keeps `query: ""` as the revision.
- **Effect:** AWS rejects an empty `versionId` with 400, so the request fails. `""` and `nil` also produce different identities for the same object.
- **Fix:** add a `""` clause, or normalize `""` to `nil` in the parser.
- **Test:** an S3 fetch with `revision: ""` should send `query_string == ""`.

### 3. Watermarked responses can advertise looser caching than the main source allows
- `lib/image_pipe/execution.ex:501-512` reduces the main source's state and the watermark assets' states to one, `Enum.min_by(states, &freshness/2)`. `response/cache_policy.ex:140-163` then takes `revalidation` and the stale window from that single state.
- **Effect:**
  - Main source `max-age=60` (no stale serving), watermark `max-age=30, stale-while-revalidate=86400`: the response gets `stale-while-revalidate=86400`.
  - Main source `must-revalidate`, watermark `max-age=30`: the response drops `must-revalidate`.
- **Fix:** combine the states field by field: earliest fresh deadline, shortest stale window, strictest revalidation.
- **Test:** a wire test with two HTTP origins using the headers above. Assert that `cache-control` has no `stale-while-revalidate=86400`.

### 4. Revalidation never sends validators when the origin varies on a header Req adds
- `lib/image_pipe/source/req_stream.ex:98` calls `Origin.conditional_headers(previous, request)` on the request built by `Req.new`, before Req's steps run.
- `Origin.from_response` stored its Vary digests from `response.request.headers`, after the steps had added `authorization` (from `auth:`) and `user-agent`.
- **Effect:** with `Vary: Authorization` and `req_options: [auth: ...]`, or with `Vary: User-Agent`, `matches?/2` (`origin.ex:128-133`) always fails. No `If-None-Match` is sent, so every revalidation downloads the full body.
- **Test:** an origin that sends `vary: Authorization` and an `etag`, and answers 304 when `if-none-match` is present. The second fetch through `with_revalidated` should return `:not_modified`.

### 5. Timing out before the response headers arrive is reported as 502, not 504
- `req_stream.ex:146-147`: before the headers arrive, every request error becomes `:connect_error`. Only a timeout during the body maps to `:receive_timeout` (`req_stream.ex:277`).
- **Effect:** if an origin accepts the connection but never responds, the result is a 502, although `receive_timeout` documents that case and maps to 504.
- **Test:** a raw socket that accepts the connection and never writes, with `receive_timeout: 100`. Expect `{:source, :receive_timeout}`.

## Plausible, worth a test before acting

### 6. Large outputs that are rejected for storage lose request dedup
- `delivery/coordinator.ex:326-327` completes the flight as `:ready` even when the commit was rejected by admission, skipped by `max_body_bytes`, or never opened.
- **Effect:** every waiter then misses the cache and generates the output itself. On a full bounded cache, N concurrent requests for a large new key decode and encode N times.

### 7. Atom header names with underscores get past the deny lists
- `req_sanitizer.ex:29-33` and `req_stream.ex:223-227` compare `to_string(name)`, so `accept_encoding` never matches `accept-encoding`.
- If Req turns `_` into `-` when it sends atom names (unconfirmed here), `headers: [accept_encoding: "gzip"]` reaches origins for immutable sources, and `proxy_authorization` survives cross-origin redirects.

### 8. Dot segments in S3 keys are sent literally
- `s3.ex:462-468` leaves `.` and `..` unencoded, and the parser does not reject them.
- `s3://allowed/..%2Fother%2Fx.jpg` requests `/allowed/../other/x.jpg`, signed with `allowed`'s credentials. AWS treats keys literally, but a proxy or S3-compatible gateway that normalizes the path would serve a bucket outside the allowlist.

## Lower confidence
- **Leftover files after a commit timeout:** `Admission.call/2` uses the default 5 s timeout. If it fires partway through publishing, the `.body` file can be renamed into place without its `.meta`, and bounded accounting never counts it.
- **Hosts allowlisted, ports not:** `allowed_hosts` checks only the hostname (`http.ex:351`), so any port on an allowed host is reachable, including through redirects. This may be the intended design.

## Checked and found sound
- **Network policy:** redirects are re-checked and pinned. Mapped and 6to4 IPv4 addresses are unwrapped. Redirect limits are correct. The body limit applies to decoded bytes, and nothing is decompressed. Streams are closed on halt and on error.
- **File source:** traversal is blocked and symlinks are checked against the root.
- **Freshness parsing:** CacheState age and Expires arithmetic, HTTPDate formats, and RefreshCache single-flight behaviour are correct.
- **ETags and 304s:** the key and ETag inputs follow AGENTS.md, and If-None-Match parsing is correct. 304 responses keep their headers.
- **Cache storage:** errors are never cached, and corrupt entries fail open. Bounded-mode byte accounting balances. Waiters are released when a leader crashes, and staging files are cleaned up.
