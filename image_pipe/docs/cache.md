# Cache storage

The `cache` option stores complete processed responses as files on disk. It
takes a keyword list, such as
`[root: "/var/cache/image_pipe/processed", max_size_bytes: 5_000_000_000]`.
In Elixir, the cache needs an ImagePipe instance (see
`ImagePipe.child_spec/1`). `image_pipe_server` runs one itself. The
options are listed in `ImagePipe.Cache.FileSystem`, and the server's
`[cache]` keys in the
[server configuration reference](../../image_pipe_server/docs/server-configuration.md#cache).
Setting up the cache is covered in
[Caching processed images](caching-processed-images.md), and how long cached
images stay valid in [Caching and freshness](caching-and-freshness.md).

## Requests that use the cache

The cache is read after the request is parsed, its signature checked, and its
source resolved. A request that fails any of those steps returns its error
without reading the cache or fetching the source.

`ImagePipe.run/4` uses the same caches when its input is
`{:source, identifier}` and it gets the same `ImagePipe.config/1` as the Plug.
It selects the same cached copy as a Plug request only when given the same
`accept` and `vary_values` (see
[sharing cache entries](combined-usage.md#processing-in-a-job)).
`{:file, path}` and `{:binary, bytes}` inputs never use the cache.

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
- `internal_cache: :disabled` turns off caching for the source: its
  processed images aren't stored, and its originals aren't remembered or
  shared between requests. The default, `:enabled`, caches whatever the
  source's storage policy allows.
- `http_cache` is described in [HTTP cache headers](cdn-http-cache.md#per-source-modes).

## What is stored

The processed-image cache stores successful responses only. A failed
request, and a crop that fell back to a default because
[content detection](content-aware-gravity.md) failed, are never stored. A
response larger than the cache's `max_body_bytes` is delivered but not
stored.

A watermarked response is stored or reused only when the original and every
watermark source permit storage and have internal caching enabled.

An instance keeps the bytes of up to 64 recently used watermark images, each
up to 1 MiB, in memory, so a watermark from an origin isn't downloaded for
every processed image. A stale watermark is checked with its origin, as an
original is.

A stored response keeps its body, content type, and two response headers:
`vary` and `cache-control`. Header names are stored in lower case.

An instance keeps each original's version and its origin freshness
headers in memory, so
[processed images outlive their original](caching-and-freshness.md#originals-and-processed-images).

## Cache key inputs

Each stored response is selected by:

- The original's version, and each watermark image's version (see
  [originals and processed images](caching-and-freshness.md#originals-and-processed-images)).
- The processing options. Two spellings of the same options select the same
  entry.
- The output format. For a URL without a `format` option this is the format
  chosen from `Accept`, not the `Accept` header itself.
- The configured output settings that apply to the image, such as the
  default qualities, encoder options, and metadata stripping.
- Where each watermark comes from and its configured opacity. Renaming a
  watermark keeps its entries.
- The content detector and model, when the crop uses detection.
- The URL's cachebuster.
- The values of the request headers and cookies named in `vary_on`.
- The credentials and headers the source sends to its origin, as a hash.
  - `ImagePipe.Source.S3` uses the configured credentials: static keys, or
    the provider and its options. Temporary credentials from a provider don't
    change the key when they rotate.
  - `ImagePipe.Source.HTTP` uses the resolved `auth:` value in its
    `req_options`. A function or MFA tuple is called once per request, so a
    new token selects new entries. With `auth: :netrc` or `{:netrc, path}`,
    the source reads the file again about a second after it changes, and its
    new credentials select new entries too.

The URL's expiry, signature, filename, `attachment` option, and `debug`
option don't select a different entry.

A source's name isn't part of the key, so renaming a source keeps its entries.
For a custom source, every option apart from the cache settings `stable`,
`cache_policy`, `internal_cache`, and `http_cache` is part of the key. Within
one source, the identity a custom adapter returns from `resolve/3` must name
everything that selects different origin bytes, or two different originals can
share cache entries (see [Writing a custom source](custom-sources.md)).

A function in the options of any source is hashed by its module, its place
in that module, and the values it captures. The `auth:` function of
`ImagePipe.Source.HTTP` is the exception, described above. A redeploy keeps
the key unless the function or the code around it changes, and functions that
capture different values select different entries. An option that holds a pid
or a reference, or a function that captures one, can change the key after a
restart or redeploy.

## Downloaded originals

Originals from HTTP and S3 sources are written to a temporary file while
they download and while requests use them, in the `image_pipe` directory
under the system temporary directory (see `System.tmp_dir/0`). Local files
are read where they are. Only the user running ImagePipe can open that
directory. When that path is a symlink, a file, or another user's directory,
those originals are held in memory instead, up to `max_body_bytes` each. The
first request that can't use the directory logs a warning naming it. With the
[default Logger](telemetry.md#logging-with-the-default-logger) attached, each
request whose original is held in memory has `staging=memory` on its line. On
a host shared with other users, set `TMPDIR` to a directory of your own.

## Writing entries

A response is processed and streamed to the client at the same time, and
written to the cache as it streams. The response never waits for the cache's
disk: each chunk is written as it arrives, and the entry is synced and stored
after the response is sent. The entry is stored
only when:

- the encoder finished,
- every chunk reached the client,
- and the body stayed within `max_body_bytes`.

A client disconnect, a failure after the first chunk, or a body over
`max_body_bytes` [leaves nothing in the cache](streaming-failures.md). The
client still receives the full response in the last case.

An original downloaded for a request is stored in the background too, while
the request processes it.

A cache drops a write when:

- it has 64 writes in progress,
- its unfinished writes hold more than 256 MiB, or a twentieth of its
  `max_size_bytes` when that is smaller,
- the client is more than 8 MiB ahead of a response's write,
- a response's write is still unfinished 30 seconds after the response
  started.

The response is still delivered, and the
[`[:cache, :stage]`](telemetry-events.md#cache-stage) event reports the
dropped write.

A write counts toward the unfinished writes as it goes, so an entry larger
than that limit is never stored. A cache of 100 MB, for example, never
stores an image over 5 MB. The cache's files can take up to
`max_size_bytes` plus the limit on unfinished writes, plus evicted entries
that requests are still reading.

Cache errors never fail a request. A failed write is logged and reported in
telemetry, and the response is delivered without being stored. A failed or
invalid read is treated as a miss, and the image is processed again under the
same key.

## Coordination limits

Each node coordinates fetching originals, making processed images, and
background checks (see
[request coalescing](caching-and-freshness.md#request-coalescing)):

- Up to 4,096 originals can be shared between requests at once, with up to
  1,024 requests waiting for them. Past either limit, a request fetches its
  original itself, without waiting. A request that waits while another
  request downloads or checks an HTTP or S3 original gives up after that
  source's `fetch_timeout` (see `ImagePipe.Source.HTTP` and
  `ImagePipe.Source.S3`) plus one second, and answers `504`. When a download
  finishes, every request waiting for it uses the downloaded original.
- Up to 16 background checks run at once. Each has a 60-second deadline.
  After a background check for a processed image finishes, no other check
  for that image starts for one second. Checks for other sizes or formats of
  the same original can still start.
- Up to 64 processed images can be made at once while other requests wait for
  them, with up to 1,024 requests waiting. Each wait lasts at most 60 seconds,
  and at most 2 seconds after the image was sent if it isn't stored by then.
  Past any of these limits, a request processes the image itself, still
  subject to the [processing pool](processing-controls.md).

## Files on disk

`ImagePipe.Cache.FileSystem` names files by hash. Paths never contain request
paths, source identifiers, header values, or cookie values. Each entry is a
body file and a metadata file holding the body's size and SHA-256 hash.
Each body is flushed to disk before it appears in the cache, so a crash or
power loss can't leave a cached body with missing data.

Before reading a cached body, the cache checks that its size matches its
metadata. An entry that fails the check, has invalid metadata, or can't be
read is logged and treated as a miss. Only the size is checked when a body is
read, so never change cache files in place: a changed body of the same size
is served as it is. A body removed after the check, for example by
[eviction](#size-limit), is still sent in full from the file already opened,
as a chunked response without `content-length`.

A path that leads outside `root` through a symlink fails as a cache error.
Each node checks each entry's directory under `root` the first time it uses
it and remembers each directory that passes. A directory later replaced by a
symlink leading outside `root` isn't noticed until the node restarts, so
restart nodes after changing symlinks under `root`. Anyone who can create
files in `root` can change cached images anyway, so only the user running
ImagePipe must be able to write there.

`ImagePipe.Cache.FileSystem.get/2` returns the whole body as a binary, for
callers outside the Plug.

### Cache root owner file

Each `root` serves one node. When an ImagePipe instance (see
`ImagePipe.child_spec/1`) starts, it writes a `.image-pipe-owner` file naming
its hostname into each cache's `root`. The instance rewrites the file every 5
seconds and deletes it when it stops. A node that restarts with the same
hostname takes the `root` over at once.

When the file names another hostname, the instance logs a warning, starts
without that cache, and checks the file every 25 seconds:

- While the other node keeps rewriting the file, the instance logs an error
  once.
- Once the file is gone, or hasn't changed since the last check, the
  instance takes the `root` over, reads the file back 5 seconds later, and
  starts using the cache. If another node took the `root` at the same time,
  the instance keeps checking.

A waiting instance starts using the cache:

- about 30 seconds after it starts, when the other node was already gone,
  for example killed with `kill -9`
- within 30 seconds of the other node stopping and deleting the file
- within about a minute of the other node stopping without deleting the file

A running node that finds its file rewritten by another node logs an error
and runs without that cache, watching the file as a starting instance does.
This happens when two nodes with the same hostname share a `root` (the node
that started later keeps it), or when a node stops rewriting its file for 25
to 50 seconds, depending on when the waiting node checks, while another node
waits for the `root`, as on a hung network mount.

If the instance can't write the file, for example because `root` isn't
writable, it logs an error and uses the cache anyway. Each image it can't
store then counts as a [write error](#usage-and-hit-rate).

### Leftover files

A node that stops abruptly, for example after a crash or `kill -9`, can leave
temporary entry files behind, and bodies that no metadata file names. A
running node can leave them too, for example when a request is killed while
its image is being written.
Metadata files the cache can't parse, such as ones another ImagePipe version
wrote, count as left behind too, and so do their bodies. ImagePipe deletes
them in the background once they are more than an hour old:

- In the cache's `root`, after its startup scan and every 24 hours while the
  instance runs.
- In the `image_pipe` directory under the system temporary directory
  (`TMPDIR`, or `/tmp`), where originals are staged while they download,
  when the `:image_pipe` application starts and every 24 hours after.

The `[:cache, :sweep]` event reports what each cleanup removed (see
[cache events](telemetry-events.md#cache-events)).

## Size limit

The cache evicts entries to stay under `max_size_bytes`. It keeps the
entries that are requested often and took the most work to make for their
size, so an AVIF made with automatic quality outlasts a JPEG thumbnail
requested as often.

`max_size_bytes` counts each entry as the disk it takes: its body rounded up
to whole 4 KiB blocks, plus one more block. A 30-byte BlurHash counts
8 KiB, so a 1 GB cache holds at most about 120,000 of them.

### Cache process and restarts

Each `root` runs one process that tracks the cache's size and chooses which
entries to keep. Only an instance starts that process (see
`ImagePipe.child_spec/1` and
[Add a processed-image cache](caching-processed-images.md#add-a-processed-image-cache)).

Request counts live only in memory. After a restart they start from zero,
and entries already on disk are next in line for eviction, roughly those
that took the least work for their size first, until they are requested
again.

The process also keeps the metadata of recently served entries in memory, so
a repeated hit reads only the body file from disk. It holds one entry's
metadata for each 50 KB of `max_size_bytes`, from 1,000 to 50,000 entries,
at about 1.8 KB each: about 36 MB for a 1 GB cache, and at most about
90 MB. Set `max_remembered_entries` to change the number of entries. This
memory isn't counted against `max_size_bytes`. A restart empties it.

### Work to make an entry

The work to make a processed image is estimated from what its request did:

- the original's format and size, and whether it has transparency
- the output's format, size, and encoder effort
- operations with a cost of their own, such as
  [`trim`](processing/crop.md#trim), [`blur`](processing/effects.md#blur),
  [`sharpen`](processing/effects.md#sharpen), and
  [`rotate`](processing/crop.md#rotate) by an angle other than a quarter
  turn, each by the size of the image it runs on
- each quality that [automatic quality](processing/output.md#autoquality)
  tries
- object detection

The estimate isn't timed, so a busy server doesn't make entries look more
expensive.

### Eviction and startup scan

`max_size_bytes` caps the total size of stored bodies in the `root`:

- To make room for a write, the cache picks 16 entries at random, chooses
  the one least worth keeping, and repeats until the write fits. If the new
  entry is worth more than the chosen entries on average, the cache evicts
  them and stores it. Otherwise it rejects the write and evicts nothing. A
  rejected entry requested at least six times is stored anyway one time in
  128. The stored bodies never exceed the cap, except briefly while the
  startup scan runs: until the scan has counted the entries on disk, writes
  are measured against only the entries counted so far.
- A rejected write's body is deleted without being synced to disk. A kept
  write is synced, then stored, evicting the entries it was compared with.
  If other writes filled the cache during the sync so that those entries no
  longer make room, the kept write is compared with more entries and can
  still be rejected.
- An entry larger than the limit on unfinished writes is never stored (see
  [writing entries](#writing-entries)).
- On startup the process lists the entries on disk in the background,
  reading only file names. If the cache is over the cap, for example after
  you lower `max_size_bytes`, it evicts in batches until it's under, so
  requests can use the cache between batches. Then it deletes
  [leftover files](#leftover-files).

A write that waits more than 5 seconds for the cache process is reported as
a [cache write](telemetry-events.md#cache-write) error with
`error: :admission_timeout`:

- A write that timed out before it was kept or rejected is dropped.
- A kept write that timed out before it was stored is still stored or
  rejected by the cache process.

### Eviction limitations

- A crash between writing a body and writing its metadata can leave a body
  file the cache doesn't track. Its size isn't counted against
  `max_size_bytes`. The first cleanup of [leftover files](#leftover-files)
  after it is an hour old deletes it, which can be up to a day later.
- Two writes to the same key at once both store their body. The last one
  wins, and the other body is deleted.
- Entries an earlier ImagePipe version stored in another format aren't
  counted against `max_size_bytes`. A cleanup of
  [leftover files](#leftover-files) deletes them, which can be up to a day
  after the upgrade for files written in its last hour.

The admission and eviction telemetry events are listed in
[cache events](telemetry-events.md#cache-events).

## Usage and hit rate

`ImagePipe.cache_stats/1` returns an `:output` entry for `cache`, with the
cache's `:bytes`, `:entries`, and `:max_bytes`, and its `:hits`, `:misses`,
`:read_errors`, and `:write_errors` since the VM started:

- Each request counts once: a hit when the processed image is served from
  the cache, a miss when it's made.
- A read error is a stored entry the cache couldn't read. The request
  treats it as a miss, so it counts as a read error and as a miss.
- A write error is an image the cache failed to store, for example because
  `root` isn't writable or its disk is full. The image is still served.
- `:counting?` is `true` until the
  [startup scan](#eviction-and-startup-scan) has counted the entries on
  disk. Until then, `:bytes` and `:entries` leave out the ones it hasn't
  reached.

The hit rate is `hits / (hits + misses)`. Each node counts only its own
requests. A cache that isn't configured isn't listed. A cache whose `root`
another node [owns](#cache-root-owner-file) isn't used by this node, so its
entry has only `refused: true` and `:max_bytes`. A cache whose process is
restarting, or busy for more than a second, can't report its size. Its
entry has `available: false`, `refused: false`, `:max_bytes`, and the
lookup counts, but no `:bytes`, `:entries`, or `:counting?`. Every other
entry has `available: true` and `refused: false`.
