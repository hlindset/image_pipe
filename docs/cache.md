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

Cache lookup follows request parsing, validation, and source resolution.
Invalid requests return before source or cache access; invalid signatures return
`403`. Failed processing is never cached.

Direct Elixir calls using `{:source, identifier}` share these pools and policies
with the Plug. Build configuration once with `ImagePipe.config/1`, pass it to
`ImagePipe.new/1` and the mount's `:config` option, and supply matching
`accept` and `request_inputs` when needed. See [shared configuration](elixir-api.md#shared-configuration).
Raw `{:file, path}` and `{:binary, bytes}` inputs bypass both pools.

## Freshness and source stability

HTTP and S3 sources use origin freshness for both original bytes and processed
responses. The default honors `s-maxage`, `max-age`, `Expires`, `Date`, `Age`,
`no-cache`, `no-store`, `private`, mandatory revalidation and
`stale-while-revalidate`. Missing freshness requires validation; there is no
heuristic TTL. Origin ETags and Last-Modified values validate originals; weak
origin ETags are never promoted to strong response ETags.
ImagePipe acts as the host's image processor: origin `no-transform` does not
cancel explicitly requested operations or change storage permission.

Storage permission is separate from freshness. Set mount defaults with
`source_cache_policy`, or override individual fields using a source adapter's
`cache_policy` (including per-bucket S3 settings):

```elixir
source_cache_policy: [
  storage: :origin,                 # :origin | :allow | :deny
  freshness: {:fallback, 300},      # :origin | {:fallback, seconds} | {:force, seconds}
  stale_while_revalidate: :origin   # :origin | :disabled | {:force, seconds}
]
```

Fallback freshness applies only when origin freshness is absent. Forced TTL
does not grant storage permission. Explicit `storage: :allow` overrides origin
private/no-store/authentication restrictions; `Vary: *` still prevents reuse.
Request URLs cannot set these host policies. Auth callbacks and S3 credentials
are resolved before keying and frozen for the fetch; only their digest enters
cache keys. Hosts implementing custom source adapters must include every
byte-selecting fetch context in their resolved source data.

`stable: :trusted` promises the source identity always names the same bytes.
Trusted sources never expire or revalidate, but remain evictable and still need
storage permission. Explicit source TTL/SWR settings conflict with this promise;
mutable mount defaults are ignored for trusted sources. Revision-addressed S3
objects are automatically stable. `internal_cache: :disabled` disables both
pools for a source; HTTP/S3 `:auto` uses origin policy. Local file sources retain
their existing stability rules and are never copied into the input pool.

## Original-byte pool

The repeatable [cache benchmarks](cache-benchmark.md) record origin savings,
latency, disk use, and memory tradeoffs for multi-variant and large-hit workloads.

Add an independently configured filesystem pool:

```elixir
input_cache: {ImagePipe.Cache.FileSystem,
  root: "/var/cache/image_pipe/originals",
  pool: :input,
  max_size_bytes: 2_000_000_000,
  node_id: "node-0"},
cache: {ImagePipe.Cache.FileSystem,
  root: "/var/cache/image_pipe/outputs",
  max_size_bytes: 5_000_000_000,
  node_id: "node-0"}
```

Use distinct roots and start `ImagePipe.Cache.FileSystem.child_spec/1` for each bounded pool.
Each owns its own byte budget, sketch, recency queues and maintenance. Output
hits do not count as input demand. Original EXIF/ICC bytes are preserved.
`pool: :input` labels the input supervisor's admission and maintenance telemetry;
the default label is `:output`. The validated mount adds the input label automatically.
The initial input adapter is filesystem storage; existing response-cache
adapters continue to work and must preserve `Entry.Metadata.source_record`.

Downloads spool completely to a temporary file before libvips opens them.
Current body/pixel limits apply when generating from input hits, while existing
successful output hits remain usable after limits are lowered. Active inputs
are pinned with temporary hard links through lazy decoding and encoding.
Incomplete transfers are never published; undecodable inputs are invalidated.
Temporary-file failures fall back to the bounded in-memory decode path.
Staging and pinned readers can temporarily exceed the retained pool budget;
their lifetime is bounded by active requests and source limits. Decoding while
the source is still downloading is tracked separately in `image_plug-yx6`.

Source version/freshness records are also stored as charged entries in the
output pool. This lets fresh outputs survive eviction of their input blobs.
These records compete for the existing pool budget; there is no unbounded
metadata cache. If all evidence is evicted, the next request acquires or
validates the source before selecting a mutable output.

## Stale-while-revalidate

An eligible stale output returns immediately while supervised work refreshes
its source and requested variant. An origin `304` retains the output without
re-encoding; a changed original selects a new byte-version key. Other variants
rebuild on demand. Output misses wait for source validation. Hits, old-input
generation, and failed refreshes never extend source deadlines. Once the stale
window ends, origin failures are returned; SWR is not stale-if-error.

Coordination is node-local. Source operations coalesce by input identity;
background jobs coalesce by output variant. Coordination allows 64 active source
keys and 1,024 waiters, with uncached fallback on saturation. Background work is
limited to 16 jobs, a 60-second deadline and a one-second retry cooldown. Jobs
survive the initiating response; process monitors release cancelled owners and
temporary files. Source version keys prevent old output workers from replacing
newer versions. Downstream headers retain source age and mandatory validation
rules. See [CDN HTTP caching](cdn-http-cache.md).

## Cache misses and streaming

Before accepting a hit, ImagePipe requires a valid body, cacheable headers, and
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

`ImagePipe.Representation.build/3` derives keys from canonical request material
and source byte identity. Mutable remote identities use the digest of a complete
original; trusted identities use the source's authoritative seed. Fresh source
evidence allows conditionals before source fetch, decode, or encode.

Input keys include source identity, digested fetch context and storage-only
partitions, including cachebusters. Transform/format/terminal choices do not
fragment originals. The input partition also partitions output storage.

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

Response hits open and pin a descriptor, verify size and SHA-256 in 64 KiB
chunks before committing headers, then rewind the same descriptor for bounded
delivery. Eviction cannot invalidate an open reader. This costs two sequential
disk passes and avoids loading a whole response into BEAM memory. HEAD and 304
paths close readers too. External in-place modification after verification can
still cause a delivery failure; published cache bodies must remain immutable.
`ImagePipe.Cache.FileSystem.get/2` returns a binary body for direct callers;
the Plug uses its file-backed read path.

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
| `:pool` | `:output` | Telemetry label; set `:input` for an input-pool supervisor. |
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
  `own_state_loaded` indicating successful local-state restoration and
  `peer_state_files` counting present peer state files on stop.
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
