# Cache

ImagePipe can cache complete encoded responses after successful processing:

```elixir
forward "/",
  to: ImagePipe.Plug,
  init_opts: [
    sources: [
      path: {ImagePipe.Source.File, root: "/srv/images", root_id: "primary"}
    ],
    cache:
      {ImagePipe.Cache.FileSystem,
       root: "/var/cache/image_pipe",
       path_prefix: "processed",
       max_body_bytes: 10_000_000}
  ]
```

Cache lookup follows request parsing, validation, and source resolution. It does
not fetch, decode, or inspect the source image. Invalid requests return before
source or cache access; invalid signatures return `403`. Failed processing is
never cached.

## Freshness and source stability

The internal cache has no TTL or origin revalidation. A hit serves the stored
body without fetching the source or checking whether its bytes changed. The
resolved source identity and byte-version seed must therefore name the same
bytes across requests and application nodes.

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

With the defaults, mutable sources skip cache lookup and staging and are fetched
and processed on every request. Forcing `internal_cache: :enabled` on a mutable
source makes freshness the caller's responsibility through request cachebusters
or external eviction.

These options are independent of client-facing `Cache-Control`, `ETag`, and
conditional `GET` handling. See [CDN HTTP caching](cdn-http-cache.md). An ETag
validates request-derived byte identity; it does not revalidate the origin.

### Deliberately not implemented

The following are intentionally out of scope for the current cache and are
tracked in [issue #44](https://github.com/hlindset/image_pipe/issues/44):

- per-entry TTL or bounded staleness independent of source identity;
- storing and honoring origin `Cache-Control` / `Expires`;
- storing origin `ETag` / `Last-Modified` validators and revalidating the origin
  with `If-None-Match` / `If-Modified-Since` (no `304` reuse against the origin).

## Cache misses and streaming

Before accepting a hit, ImagePipe requires a binary body, cacheable headers, and
a matching content type: a known output format for an image, or a well-formed
media type for `{:complete_body, content_type}`. Valid hits bypass source fetch,
decode, transforms, and encoding.

If cache entry validation fails, ImagePipe treats the hit like a miss. It
reprocesses through a supervised source session using the same cache key and
emits cache read telemetry for the invalid entry.

Cache misses and read errors stream through a supervised source session that
owns fetch, decode, transforms, encoding, and staging. It returns the first
encoded chunk before response headers commit, and `ImagePipe.Response.Sender`
pulls later chunks on demand.

The session stages each encoded chunk as it sends it. The entry becomes visible
only after:

- the encoder stream finishes,
- the sender has successfully delivered every chunk returned by the session,
- and the staged body stayed within `:max_body_bytes`.

Client disconnects, owner process exits, explicit cancellation, source or encode
failures after the first chunk, and incomplete streams abort the staged entry and
don't write cache. If the staged body crosses `:max_body_bytes`, ImagePipe drops
cache staging, continues delivering the response, and skips the cache write.

Staging and commit errors fail open: delivery continues, telemetry records the
cache error, and the entry is not stored.

## Cache keys

`ImagePipe.Representation.build/3` derives keys entirely from pre-fetch
material. This allows a conditional `GET` to resolve before fetch, decode, or
encode.

Cache keys include:

- resolved source identity and byte-version seed
- the core execution epoch
- canonical request material: the ordered groups, the
  EXIF auto-orient flag, the terminal identity, the canonical output plan, and the
  resolved detector identity
- the negotiation outcome and effective output policy material
- the plan's cachebuster and the request values named by the mount-level
  `storage_inputs: [{:header, name}, {:cookie, name}]`

The last group is `storage_only`: it partitions internal storage without
changing delivered bytes, so the ETag excludes it. See
[CDN HTTP caching](cdn-http-cache.md).

ImagePipe reserves `Accept` for automatic output normalization; the normalized
negotiation outcome enters the key instead of the raw header value.

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

Filesystem metadata has its own `metadata_version` and records the body
filename, byte size, and SHA-256 digest. Bodies are content-addressed by digest.

Missing files are misses. Invalid metadata and filesystem read failures are
logged, emitted as cache-read telemetry, and treated as misses.

Adapter errors fail open and log a warning. Invalid configuration fails Plug
initialization. Bodies over cache `:max_body_bytes` are still delivered but not
stored; the option must be `nil` or a non-negative integer.

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
