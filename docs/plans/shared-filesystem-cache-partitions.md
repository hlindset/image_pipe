# Shared filesystem cache with owned partitions

Status: proposed implementation specification, 2026-09-24. Tracked by
`image_plug-015`. This supersedes the [earlier shared-cache design](shared-filesystem-cache.md).
No shared filesystem profile is qualified yet.

## Requirements and consistency

Keep `ImagePipe.Cache.FileSystem` as the local, exclusively owned-root adapter.
Add `ImagePipe.Cache.SharedFileSystem` for originals, source validation records,
and encoded outputs on a genuinely shared volume. A partition is an instance's
directory, not a separate device. Root assignment remains host configuration.

Nodes may independently serve different source versions while each version's
origin-derived freshness policy permits it. Learning a changed source on A does
not immediately invalidate B's still-fresh version. Discovery, index warmup,
restart, and adoption never restart freshness or stale-serving allowances.
Preserve validation evidence, Date/Age handling, absolute deadlines, byte identity,
and the source/request context that makes the evidence reusable. Use a documented
clock-skew allowance for shared deadlines; revalidate when they cannot be trusted.

Only complete, matching metadata and bytes may be served. Storage failures,
including a full volume, fail open: successfully generated responses are still
delivered. Source and processing failures keep their normal behavior. Duplicate
generation and mistaken eviction are acceptable; incorrect bytes and extended
freshness are not. Bounds apply to memory, queued work, request cache waits, and
background I/O. Cache deadlines do not bound origin fetch or transformation time.

## Layout, publication, and readers

Every adapter incarnation allocates a unique directory; identifiers are never
reused. One instance publishes into it, all instances may read it, and maintenance
may reclaim inactive directories. Schematic layout:

```text
partitions/<incarnation>/
  heartbeat
  inventory
  outputs/<shard>/<key>/<generation>/{meta,body}
  sources/<shard>/<input-key>/<generation>/meta
  originals/<shard>/<input-key>/<byte-identity>/<generation>/{meta,body}
  staging/<operation-id>/...
```

Encode or digest path components. Metadata identifies the namespace, exact key,
generation, body identity/length, and applicable freshness evidence. Originals
are scoped by input key as well as byte identity; opaque identity seeds alone
must not make distinct sources share bodies. Validate external serialized data.

Prepare a generation in staging, close its files, and publish the complete unit
with atomic rename within the same filesystem. Never overwrite published body
bytes or reuse a generation name. Missing or corrupt members are a miss, with
bounded retry of other candidates. Crash durability may lose cache entries;
recovery must never expose partial entries. Ambiguous filesystem results require
checking the exact operation destination before retrying or accounting success.

Acquire a stable body before committing a response or handing a path to lazy
decoding. Use a held resource with proven lifetime semantics, or materialize a
request-local copy. Release handles on completion and caller death. Such temporary
reader resources are distinct from durable adoption and must have their own
budget and cleanup. Disappearance before acquisition triggers retry/miss; cleanup
after acquisition must not truncate a response or break a decode already started.

## Lookup and source selection

1. Try the bounded local location index, then validate/open the candidate.
2. On missing, stale, or unusable hints, search predictable key paths across known
   partition directories. Refresh the cached partition list on a miss before
   declaring a miss, within the cache I/O budget. Visibility lag may still miss.
3. Successful disk discovery updates the local index. Otherwise fetch/generate
   through the existing request lifecycle and attempt local publication.

Coalesce same-key discovery locally. Bound candidate enumeration, concurrency,
and time; exhausting a budget yields an ordinary cache bypass. Avoid a full-volume
scan on the request path. Track cache misses versus budget exhaustion separately.

Use an entry-count and memory-bounded index with a small bounded number of
locations per key. LRU is sufficient for this disposable index; actual successful
requests establish recency. Retention/adoption uses W-TinyLFU separately.

There is no global latest-generation pointer. For outputs, any valid generation
for the exact representation key is eligible. For sources, retain a locally
selected fresh record until policy requires validation; on discovery select an
eligible record deterministically without claiming that its timestamp proves it
is the newest origin version. Never use an older record to evade required local
revalidation or a locally known invalid revision. An expired record may supply
validators, but stale serving must follow the existing policy. A `304` produces
new validation evidence for the same bytes; missing required original bytes may
necessitate an unconditional fetch. Late invalidation affects only its expected
revision, never a newer local selection. Global immediate invalidation is outside
this consistency contract.

The existing pluggable input-cache foundation is reusable, but its documented
single-authority/atomic-ownership contract needs explicit revision. Define
coordination scope per adapter, preserve local same-key validation serialization
and expected-revision invalidation, and test the request lifecycle accordingly.
Output-only shared caching must explicitly select its source-state owner rather
than accidentally inheriting a custom-adapter fallback. Keep optional original
storage and record-only validation publication working.

## Warmup inventories

Each writer periodically atomically replaces a small inventory of useful keys
and exact generation locations. Select candidates from local protected entries
and W-TinyLFU estimates. The frequency sketch scores known keys; it cannot list
popular keys by itself. Bound inventory bytes/count, publication frequency, age,
and startup work. Include format/namespace and incarnation identifiers.

A new instance serves requests immediately while reading inventories in the
background and validating candidates on disk. Warmup seeds only a fraction of
its location-index budget, with low initial priority. Missing, stale, incompatible,
or corrupt inventories are harmless; disk discovery finds unlisted entries.
Inventories do not extend freshness, create local access frequency, or trigger
adoption. Actual local requests determine what is worth retaining.

## Admission-controlled adoption

A foreign hit records genuine local demand and may be served without retention.
Only entries that pass local W-TinyLFU admission are adopted and charged to the
local retention budget. Admission need not mean a fixed hit threshold: use the
policy's competition with retained entries. Coalesce duplicate adoption attempts.

Adoption creates a new local generation, preferably by hard-linking the immutable
body into local staging, then publishing metadata that preserves the original
identity and freshness evidence. This requires supported hard links within the
same filesystem and compatible permissions. Hard links share bytes, not copy on
write; bodies must never be modified through either name. Use bounded copying
through the same publication protocol where hard links are unavailable.

The source writer need not be dead. Deleting its link does not remove a successfully
adopted local link. If source cleanup wins before adoption completes, retry another
candidate or abandon adoption; never publish incomplete metadata/body pairs.
The current response need not wait for durable adoption once its reader is safe.

Charge full logical entry size to every adopting partition. This conservatively
double-counts shared blocks but avoids distributed reference accounting. Deleting
one hard link is not evidence of physical bytes reclaimed. Record logical retention
and observed filesystem capacity separately.

## Eviction, restart, and abandoned directories

Each instance admits and evicts its own retained entries within a configured
local byte budget. A root-wide soft target uses approximate per-partition usage
to request proportional local reductions; stale/missing reports permit overshoot.
Independent sweeps may reclaim inactive directories. Bound and stagger work;
overlapping passes may over-evict, but must remain safe. Include metadata, staging,
reader resources, copy fallback, and failed removals in capacity planning. Operators
may enforce an external storage ceiling where supported; the adapter provisions
no quota. Neither a heartbeat nor a usage snapshot is authoritative accounting.

Crashes lose the memory index and may leave staging. Published generations and
the last inventory remain readable. Restart allocates a fresh incarnation and
warms from all suitable inventories, including its predecessor's. Useful entries
survive old-directory cleanup only if admitted and adopted elsewhere.

Heartbeat inactivity beyond a generous configured grace period makes a directory
eligible for reclamation. It is not proof its writer is dead. The protocol must
tolerate deletion racing readers, publication, adoption, and a resumed writer.
Cleanup targets exact incarnation/generation names, never a logical node alias.
An instance that detects reclamation rotates to a new incarnation; delayed work
must not corrupt another incarnation or extend old evidence. A late complete
immutable publication may be an extra reclaimable entry, not a correctness failure.

The first implementation gate must specify retirement, ancestor recreation,
heartbeat recreation, outstanding I/O, and repeated cleanup precisely. A marker
check before writing is not fencing. Demonstrate safe outcomes even when the
writer never observes a cleanup marker. Do not promise cancellation of a kernel
filesystem operation merely because an Erlang caller timed out. Bound stuck
workers/resources and use uncached bypass when saturated. Failure to reclaim space
reduces caching availability and must be observable.

## Runtime and filesystem requirements

Use the existing cache behaviours and narrow concrete internal modules. Supervise
local index/admission state and bounded I/O/background workers; keep blocking mount
I/O out of coordinator callbacks. Reuse existing sketch, scoring, serialization,
and path helpers only where contracts match. No new dependency is required by
this specification.

Qualify concrete shared mount/client configurations for complete rename publication,
visibility, unlink/read lifetime, hard-link behavior or copy fallback, crash/reconnect,
and stalled operations. Linux NFSv4/EFS remains a candidate, not the architecture's
exclusive backend or an ownership-lock prerequisite. SMB requires its own evidence.
Volumes private to each container cannot provide cross-node reuse merely by using
this adapter. No mount profile is supported solely by its protocol name.

Defer gossip, distributed Erlang, Nebulex/CRDT replication, Bloom filters, reflinks,
and replicated global indexes. Measure a concrete need before adding them. The
filesystem plus local state must remain sufficient if optional acceleration is
added later.

## Validation and delivery

Use deterministic interleavings between independent instances as primary protocol
coverage: publication/cleanup/adoption races, crash at each publication step,
uncertain outcomes, delayed I/O, false inactivity, restart, hard-link and copy
paths, reader lifetime, and failed deletion. Property tests cover complete matching
generations and unchanged freshness through discovery/adoption. Cover index and
inventory budgets, actual-demand-only admission, snapshot staleness, and bounded
work under many partitions/misses.

Request-level tests cover originals and output-only configurations, changed pixels,
independently fresh versions, `304`, stale policies, expected-revision invalidation,
missing bodies, full storage, and fail-open delivery. Preserve local adapter tests.
A small independent-BEAM, cross-machine suite verifies actual mount assumptions;
single-BEAM scheduling cannot model client caches or server recovery by itself.

Measure cold-node latency, steady-state throughput, metadata operations per lookup,
index warmup benefit, adoption I/O, and cleanup overhead. Choose budgets, intervals,
and grace periods from evidence. Add telemetry for lookup/discovery, warmup, admission,
adoption, timeout/saturation, recovery, and logical/physical storage observations;
update Logger, Trace.Capture/exporter coverage, and deployment docs together.

Implementation dependencies and progress live in Beads. The protocol gate precedes
bounded I/O, generations/readers, per-node source semantics, adapter integration,
adoption, inventories, and capacity maintenance. Qualification gates support claims,
not local development of the protocol.
