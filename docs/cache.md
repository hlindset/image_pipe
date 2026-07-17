# Cache

ImagePipe can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePipe.Dialect.Imgproxy,
  init_opts: [
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    cache:
      {ImagePipe.Cache.FileSystem,
       root: "/var/cache/image_pipe",
       path_prefix: "processed",
       max_body_bytes: 10_000_000,
       key_headers: [],
       key_cookies: []}
  ]
```

Cache lookup happens only after request parsing, plan validation, and source
resolution. A lookup doesn't fetch, decode, or read metadata from the source
image. Invalid parser and planner requests return before source fetch or cache
access. Invalid Imgproxy signatures return `403`. Parser, planner, source
fetch, decode, transform, negotiation, and encode errors are never cached.

## Freshness and source stability

The internal cache has no time-based freshness and performs no origin
revalidation. A cache hit is served from the stored encoded body without
re-fetching the source, without re-reading source metadata, and without checking
whether the origin bytes changed. Reuse validity is therefore a property of the
*source identity*, not of elapsed time: the cache assumes that a given resolved
source identity always names the same bytes.

That assumption is made explicit per source through the `:stable` option, and
whether the internal cache is used at all is gated on it through the
`:internal_cache` option.

- `:stable` (`:auto` | `:trusted`, default `:auto`) asserts whether the resolved
  source identity names immutable bytes. `:trusted` means the caller guarantees
  the bytes at that identity never change in place. `:auto` treats the source as
  mutable, except for `ImagePipe.Source.S3` objects fetched with a revision,
  which are stable under `:auto` because the version is part of the fetch.
- `:internal_cache` (`:auto` | `:enabled` | `:disabled`, default `:auto`)
  decides whether responses for the source may be read from and written to the
  configured cache. Under `:auto`, the internal cache is **enabled only when the
  source is stable**.

The consequence is that, with default settings, ImagePipe does not internally
cache mutable sources at all. A request against a non-stable source skips cache
lookup and cache staging entirely and re-fetches and re-processes the origin
every time, so it cannot serve an indefinitely stale transformed response. The
"stale forever" failure mode only arises if a deployment deliberately forces
`internal_cache: :enabled` on a mutable source; in that case freshness is the
caller's responsibility, managed through cachebusters in the request or external
eviction of the cache (including bounded mode's size-driven eviction, below).

`:stable` and `:internal_cache` are independent of the client-facing HTTP cache
headers (`Cache-Control`, `ETag`, conditional `GET` / `304`), which are governed
separately and described in [docs/cdn-http-cache.md](cdn-http-cache.md). The
client-side `ETag` is a validator over request inputs and does not revalidate the
origin either.

### Deliberately not implemented

The following are intentionally out of scope for the current cache and are
tracked in [issue #44](https://github.com/hlindset/image_pipe/issues/44):

- per-entry TTL or bounded staleness independent of source identity;
- storing and honoring origin `Cache-Control` / `Expires`;
- storing origin `ETag` / `Last-Modified` validators and revalidating the origin
  with `If-None-Match` / `If-Modified-Since` (no `304` reuse against the origin).

Entry metadata is versioned (the filesystem adapter carries an independent
`metadata_version`; see below), so freshness or validator fields can be added in
a migration-safe way if mutable origins become a first-class use case.

## Cache misses and streaming

On cache read, ImagePipe validates the returned entry before treating it as a
hit. The entry must have a binary body, cacheable headers, and one of the
supported output content types: JPEG, PNG, WebP, or AVIF. If that check passes,
ImagePipe sends the stored body without fetching, decoding, transforming, or
encoding the source image.

If cache entry validation fails, ImagePipe treats the hit like a miss. It
reprocesses through a supervised source session using the same cache key and
emits cache read telemetry for the invalid entry.

Configured cache misses and cache read errors stream through a supervised source
session. The session owns source fetch, decode, transform execution, output
encoding, and cache staging. It returns the first encoded chunk before ImagePipe
commits response headers, then `ImagePipe.Response.Sender` pulls later chunks on
demand.

For those streamed cache misses, the source session writes encoded chunks into a
cache sink as it returns them to the sender. ImagePipe makes the staged cache
entry visible only after:

- the encoder stream finishes,
- the sender has successfully delivered every chunk returned by the session,
- and the staged body stayed within `:max_body_bytes`.

Client disconnects, owner process exits, explicit cancellation, source or encode
failures after the first chunk, and incomplete streams abort the staged entry and
don't write cache. If the staged body crosses `:max_body_bytes`, ImagePipe drops
cache staging, continues delivering the response, and skips the cache write.

Cache commit errors after successful streamed delivery fail open. The client
keeps the response body that was already delivered. ImagePipe emits cache write
telemetry and doesn't replace that response with a cache error. Cache staging
open or write errors also fail open and skip the cache write.

## Cache keys

Cache keys include:

- resolved source identity
- canonical Plan operation key data
- the cache key's transform key data version
- configured `:key_headers` and `:key_cookies`
- normalized automatic-output inputs when output is automatic: detected modern
  output candidates plus `:auto_jpeg_xl`, `:auto_avif`, and `:auto_webp` flags

ImagePipe reserves `Accept` for automatic output normalization and rejects it in
`:key_headers` so raw `Accept` values don't enter cache key material.

Cache keys exclude:

- request signatures
- raw request paths
- query strings
- raw `Accept` headers
- source metadata
- decoded image properties
- source-aware execution choices
- unconfigured headers and cookies

Key data includes a schema version and deterministic primitive serialization.
Explicit formats bypass `Accept` negotiation, so they don't vary by `Accept`.

## Stored headers

The cache stores only `vary` and `cache-control` response headers. It normalizes
header names to lowercase and preserves duplicate allowed headers.

## Filesystem adapter

`ImagePipe.Cache.FileSystem` requires an absolute `:root`. The optional
`:path_prefix` must be relative and rejects backslashes, duplicate-slash empty
segments, `.`, `..`, and `~`-prefixed path segments. Generated hashes determine
cache paths, not request, source, header, or cookie data.

Filesystem metadata has an independent `metadata_version` and includes the
cached body filename, byte size, and SHA-256 digest. Body files are
content-addressed by digest.

Missing files are cache misses. Invalid metadata and filesystem read problems
are cache read errors from the adapter. The cache coordinator logs them, emits
cache read telemetry, and treats the lookup as a miss.

Adapter errors returned to the cache coordinator fail open and log a warning.
Plug initialization rejects invalid cache configuration. The client still
receives encoded response bodies over the cache `:max_body_bytes` limit, but the
cache skips storage. `:max_body_bytes` must be `nil` or a non-negative integer.

The filesystem adapter validates generated paths under the configured root
with `Path.safe_relative/2`, so paths that escape through symlinks fail as cache
path errors.

## Bounded mode

By default the filesystem cache grows without an upper size limit. Setting
`:max_size_bytes` switches `ImagePipe.Cache.FileSystem` into bounded mode, where
a cost-aware W-TinyLFU admission and eviction policy keeps the total size of
stored body files at or under the configured cap.

```elixir
cache:
  {ImagePipe.Cache.FileSystem,
   root: "/var/cache/image_pipe",
   max_size_bytes: 5_000_000_000,
   node_id: System.get_env("POD_NAME", "node-0")}
```

Bounded mode is opt-in. Without `:max_size_bytes`, the adapter runs unbounded and
ignores every other option in this section.

### Node identity and the supervision tree

Bounded mode runs a per-node `Admission` GenServer that owns the size budget,
the admission policy, and the persisted frequency sketch. It requires a stable
`:node_id` string. The `:node_id` names the per-node persisted state file, so it
must stay stable across restarts of the same node. On Kubernetes, StatefulSet
pods get stable ordinal names (e.g. `image-pipe-0`, exposed via `POD_NAME` from
the downward API), which make good `:node_id` values; Deployment/ReplicaSet pods
get a random suffix that changes on every restart, so their pod names must not
be used.

`ImagePipe.Cache.FileSystem.child_spec/1` returns a supervisor spec (a `Registry`
plus the `Admission` process) when `:max_size_bytes` is set, and `:ignore`
otherwise. Add it to your application's supervision tree **before** the Plug
endpoint starts serving requests, using the same options you pass to the cache:

```elixir
children = [
  ImagePipe.Cache.FileSystem.child_spec(cache_opts),
  {Bandit, plug: MyApp.Endpoint}
]
```

Bounded commits fail closed: if no `Admission` process is running for a request's
`{root, node_id}`, the cache skips the write rather than leaving an untracked
entry on disk. Starting the cache supervisor before the endpoint avoids dropping
writes during startup.

### Configuration options

All bounded options other than `:max_size_bytes` and `:node_id` have derived or
fixed defaults; most deployments only set the first two. Interval options are in
seconds.

| Option | Default | Meaning |
| --- | --- | --- |
| `:max_size_bytes` | — (enables bounded mode) | Soft cap on total stored body bytes. |
| `:node_id` | — (required) | Stable per-node identity; names the persisted state file. |
| `:state_dir` | `<root>/.cache_state` | Directory holding per-node `<node_id>.state` files. |
| `:window_ratio` | `0.01` | Fraction of the cap used for the admission window. `0.0` disables the window. |
| `:sketch_depth` | `4` | Count-Min Sketch hash rows. |
| `:sketch_width` | derived from cap | Count-Min Sketch counters per row. |
| `:aging_sample_size` | derived from cap | Increments between sketch aging passes. |
| `:doorkeeper_cardinality` | derived from cap | Bloom doorkeeper capacity. |
| `:doorkeeper_fpr` | `0.01` | Bloom doorkeeper false-positive rate. |
| `:eviction_victim_limit` | `64` | Max victims considered per reconcile pass. |
| `:flush_interval` | `30` | Seconds between state-file flushes. |
| `:cleanup_interval` | `3600` | Seconds between stale peer-state cleanups. |
| `:reconcile_interval` | `60` | Seconds between background reconcile passes. |
| `:state_ttl` | `604_800` | Seconds before an untouched peer state file is stale. |

### Soft-cap semantics and boot reconciliation

The cap is a soft cap on tracked body bytes. On each commit, admission decides
whether to admit the new entry (evicting lower-value entries as needed) or reject
it. Rejected and superseded bodies are deleted from disk so on-disk usage tracks
admission's accounting. Entries larger than the cap are rejected outright; the
written body and metadata are cleaned up and the commit reports an admission
rejection.

On boot, `Admission` scans the existing on-disk entries into its policy state and
reconciles down to the cap, so a node that restarts against a populated cache
directory converges without serving an over-cap cache.

### Multi-node warm start

Each node periodically persists its frequency sketch to `<node_id>.state` in
`:state_dir`. On boot a node reads every peer `*.state` file in that directory
and merges their frequencies into its starting sketch, so a freshly started node
inherits cluster-wide popularity information instead of cold-starting. The Bloom
doorkeeper is per-node and is not persisted. Peer state files older than
`:state_ttl` are removed during periodic cleanup.

### Telemetry

Bounded mode emits these additional events under the configured telemetry prefix
(default `[:image_pipe]`):

- `[..., :cache, :warm_start, :start | :stop]` — boot warm start, with
  `own_state_loaded` and `peer_state_files` metadata on stop.
- `[..., :cache, :admission, :stop]` — each admission decision, with `result`
  (`:admitted` / `:rejected`), `reason` on rejection, and `victim_count`.
- `[..., :cache, :eviction, :stop]` — reconcile-driven eviction, with `count`
  and `bytes` measurements and `trigger: :reconcile`.
- `[..., :cache, :flush, :stop]` — state-file flush, with flushed `bytes`.
- `[..., :cache, :cleanup, :stop]` — stale peer-file cleanup, with `removed`.

### Known limitations

- Admission serializes through a single GenServer per `{root, node_id}`, so it is
  a per-node coordination point rather than a sharded one.
- A crash between writing a body file and recording it can leave an orphan body
  on disk; boot reconciliation accounts for on-disk entries, and unaccounted
  bodies are bounded by the cap rather than tracked individually.
- Concurrent commits to the same key race on the body file; the last commit wins
  and the superseded body is deleted.
