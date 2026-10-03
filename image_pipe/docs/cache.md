# Cache storage

ImagePipe has two caches: `cache` stores complete processed responses, and
`input_cache` stores originals fetched from remote sources. Both take
`{ImagePipe.Cache.FileSystem, options}`. The adapter's options are listed in
`ImagePipe.Cache.FileSystem`, and the server's `[cache]` keys in the
[server configuration reference](../../image_pipe_server/docs/server-configuration.md#cache).
Setting up the caches is covered in
[Caching processed images](caching-processed-images.md), and how long cached
images stay valid in [Caching and freshness](caching-and-freshness.md).

## Requests that use the cache

The cache is read after the request is parsed, its signature checked, and its
source resolved. A request that fails any of those steps returns its error
without reading the cache or fetching the source.

`ImagePipe.run/4` uses the same caches when its input is
`{:source, identifier}` and it gets the same `ImagePipe.config/1` as the Plug.
It selects the same cached copy as a Plug request only when given the same
`accept` and `request_inputs` (see
[sharing cache entries](combined-usage.md#share-cache-entries)).
`{:file, path}` and `{:binary, bytes}` inputs never use either cache.

## Source cache settings

The `source_cache_policy` option sets the cache policy for every source. A
source's own `cache_policy` option replaces it field by field, and the S3
adapter also accepts one per bucket:

```elixir
source_cache_policy: [
  storage: :origin,                 # :origin | :allow | :deny
  freshness: {:fallback, 300},      # :origin | {:fallback, seconds} | {:force, seconds}
  stale_while_revalidate: :origin   # :origin | :disabled | {:force, seconds}
]
```

`ImagePipe.Source.CachePolicy` describes each field. The other per-source
settings, `stable`, `internal_cache`, and `http_cache`, are listed in
`ImagePipe.Source.CacheSettings`:

- `stable: :immutable` marks a source whose identifiers always name the same
  bytes.
- `internal_cache: :disabled` turns off both caches for the source. The
  default, `:auto`, caches whatever the source's storage policy allows.
- `http_cache` is described in [HTTP cache headers](cdn-http-cache.md#per-source-modes).

## What is stored

The processed-image cache stores successful responses only. A failed
request, and a crop that fell back to a default because
[content detection](content-aware-gravity.md) failed, are never stored. A
response larger than the cache's `max_body_bytes` is delivered but not
stored.

A stored response keeps its body, content type, and two response headers:
`vary` and `cache-control`. Header names are stored in lower case.

Each original's version and its origin freshness headers are also stored in
the processed-image cache. They let
[processed images outlive their original](caching-and-freshness.md#originals-and-processed-images),
and count against the processed-image cache's size.

## Cache key inputs

Each stored response is selected by:

- The original's version (see
  [originals and processed images](caching-and-freshness.md#originals-and-processed-images)).
- The processing options. Two spellings of the same options select the same
  entry.
- The output format. For a URL without a `format` option this is the format
  chosen from `Accept`, not the `Accept` header itself.
- The content detector and model, when the crop uses detection.
- The URL's cachebuster.
- The values of the request headers and cookies named in `storage_inputs`.
- The credentials and headers the source sends to its origin, such as an S3
  access key or the result of an HTTP auth callback. They are resolved once
  per request and enter the key only as a hash.

The URL's expiry, signature, filename, `attachment` option, and `debug`
option don't select a different entry.

The originals cache uses the original's identifier, the cachebuster, the
`storage_inputs` values, and the origin credentials. Processing options and
output format don't, so every size and format of one original shares one
stored copy.

A custom source adapter must include everything that selects different
origin bytes in the identity it returns from `resolve/3`, or two different
originals can share cache entries (see [custom adapters](sources.md#custom-adapters)).

## Originals cache

`input_cache` accepts only `ImagePipe.Cache.FileSystem`, with a `root`
different from the processed-image cache's. Each cache has its own size limit
and eviction. Serving a processed image from the cache doesn't count as a
request for its original.

- Originals are stored byte for byte, including their EXIF and ICC data.
- Local files are copied in only when their source sets `copy: :keep` (see
  [local files](sources.md#local-files)).
- A download is stored only once it completes.
- An original that fails to decode is removed from the cache.
- Making a new processed image from a stored original applies the current
  `max_body_bytes` and pixel limits. Processed images already in the cache
  are still served after you lower those limits.
- Downloads in progress, and originals being read by a request, can take the
  cache over its `max_size_bytes` for as long as those requests run.

## Writing entries

A response is processed and streamed to the client at the same time, and
written to the cache as it streams. The entry is stored only when:

- the encoder finished,
- every chunk reached the client,
- and the body stayed within `max_body_bytes`.

A client disconnect, a failure after the first chunk, or a body over
`max_body_bytes` [leaves nothing in the cache](streaming-failures.md). The
client still receives the full response in the last case.

Cache errors never fail a request. A failed write is logged and reported in
telemetry, and the response is delivered without being stored. A failed or
invalid read is treated as a miss, and the image is processed again under the
same key.

## Coordination limits

Each node coordinates fetches of originals and background checks
(see [request coalescing](caching-and-freshness.md#request-coalescing)):

- Up to 64 originals can be fetched or checked at once, with up to 1,024
  requests waiting for them. Past either limit, a request fetches its
  original itself, without waiting and without caching it.
- Up to 16 background checks run at once. Each has a 60-second deadline. A
  failed check isn't retried for one second.

Limits for processed images are in
[output-cache request coalescing](processing-controls.md#output-cache-request-coalescing).

## Files on disk

`ImagePipe.Cache.FileSystem` names files by hash. Paths never contain request
paths, source identifiers, header values, or cookie values. Each entry is a
body file and a metadata file holding the body's size and SHA-256 hash.

Before sending a cached response, the cache checks the body's size and hash.
An entry that fails the check, has invalid metadata, or can't be read is
logged and treated as a miss. Files must not be changed in place after they
are written: a change made after the check can fail the response midway.

A path that leads outside `root` through a symlink fails as a cache error.
`ImagePipe.Cache.FileSystem.get/2` returns the whole body as a binary, for
callers outside the Plug.

## Bounded mode

`max_size_bytes` turns on bounded mode. Without it the cache grows without
limit. The other bounded-mode options, listed in
`ImagePipe.Cache.FileSystem`, require `max_size_bytes`, and all except
`node_id` have defaults.

### Node IDs and supervision

Bounded mode needs `node_id`, the name of this node's state file
`<node_id>.state`. It must stay the same across restarts and differ between
nodes that share a `root` (see
[run several replicas](caching-processed-images.md#run-several-replicas)).

Each `root` and `node_id` pair runs one process that tracks the cache's size
and chooses which entries to keep. A bounded cache must be configured on an
instance, which starts that process (see `ImagePipe.child_spec/1` and
[Bound the cache size](caching-processed-images.md#bound-the-cache-size)).

### Size cap and startup scan

`max_size_bytes` is a soft cap on the total size of stored bodies:

- Each write either stores the new entry, evicting less valuable entries to
  make room, or rejects it. Rejected and replaced bodies are deleted from
  disk.
- An entry larger than `max_size_bytes` is always rejected.
- On startup the process scans the entries already on disk in the
  background, then evicts until the cache is at or under the cap.
- Every `reconcile_interval` (60 seconds by default) it evicts again until
  the cache is at or under the cap. Evictions from this pass and the
  startup scan are reported with `trigger: :reconcile`.

### Warm start from peers

Each node writes its request counts to `<node_id>.state` in `state_dir`
every `flush_interval`. On startup a node merges the counts from every peer
state file younger than `state_ttl`, so a new node keeps entries that are
popular across the cluster. Older peer files are deleted every
`cleanup_interval`. Counts of responses requested only once are not saved.

### Bounded-mode limitations

- All writes to one `root` and `node_id` go through one process.
- A crash between writing a body and writing its metadata can leave a body
  file the cache doesn't track. The startup scan reads metadata files only,
  so that body doesn't count against `max_size_bytes`.
- Two writes to the same key at once both store their body. The last one
  wins, and the other body is deleted.

The bounded-mode telemetry events are listed in
[cache events](telemetry-events.md#cache-events).
