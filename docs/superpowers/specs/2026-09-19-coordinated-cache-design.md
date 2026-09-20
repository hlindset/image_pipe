# Coordinated source and response caching

Implementation design for Beads epic `image_plug-x73`. This describes the target
contract; `docs/cache.md` continues to describe the shipped implementation.
Progress and dependencies live in Beads.

## Outcome

A remote original can supply many output variants without repeated downloads.
Original encoded bytes and processed responses occupy separately bounded
W-TinyLFU pools. Both use the same effective source freshness and storage policy.
Existing output hits avoid source work whenever that policy permits it.

## Policy decisions

Host configuration separates three concerns:

| Concern | Default | Explicit host choices |
| --- | --- | --- |
| Permission to retain shared entries | Respect origin restrictions | Allow or deny storage |
| Freshness | Honor origin freshness | Fallback TTL or forced TTL |
| Serving stale | Honor applicable origin SWR permission | Disable or explicitly override the stale window |

A fallback TTL applies only when explicit origin freshness is absent. It does
not override `no-cache`, `no-store`, `private`, or mandatory revalidation.
Forced freshness and forced storage are distinct choices. All durations are
validated nonnegative seconds; zero means immediately stale or no stale window.
Configuration belongs to mounts and source adapters, never request URL options.
Per-source fields override corresponding mount defaults; omitted fields inherit.
Invalid host configuration is rejected at initialization.

The existing `stable: :trusted` setting asserts that the source identity always
names the same bytes. For this mode, neither pool expires or revalidates entries.
Storage permission remains separate, and both pools may evict entries. Reject
contradictory explicit TTL/SWR configuration for a trusted immutable source.
An inherited mount TTL remains a default for mutable sources; the source's
immutable promise takes precedence over that default.
Revision-addressed S3 objects retain their automatic stability contract.

Origin-respecting mode follows RFC 9111 and RFC 5861: shared-cache freshness uses
`s-maxage`, then `max-age`, then `Expires`, accounting for `Date`, `Age`, and time
spent in transit. Store response/request timing and validators for revalidation.
Do not infer freshness from a filename or reset age when producing a derivative.
Malformed or ambiguous metadata must not accidentally grant reuse. The initial
implementation uses no heuristic freshness.

Origin `Vary` is matched against actual outbound request headers. Authorization
and mount/source namespaces must be represented where necessary to avoid sharing
across distinct fetch contexts. `Vary: *` prevents ordinary reuse. Configured
storage partitions are not an authorization check.

For GitHub #59, default downstream policy to `private` when cookie storage inputs
are configured. A documented host choice may permit public caching; existing
host privacy headers and `Set-Cookie` must not be weakened by generated headers.
This does not change byte identity or treat cookie partitioning as authorization.

ImagePipe is the origin of the requested derived representation, rather than a
transparent intermediary serving the upstream representation. Origin
`no-transform` does not change the host-requested image operations or grant or
deny storage. Storage and freshness follow the separate origin directives.
Hosts must authorize the source and the transformations they expose.

## Identity and persistence

Keep three distinct identities:

1. Input lookup identity: resolved source identity, fetch context, origin Vary
   values, and relevant storage partitions including the cachebuster.
2. Source byte identity: an authoritative immutable/versioned seed, or the digest
   of a successfully fetched complete original for a mutable source.
3. Output identity: source byte identity plus canonical processing/output intent
   and output storage partitions.

Output geometry, terminal, format, and client output negotiation do not fragment
input lookup identity. Origin negotiation may partition inputs independently.
Changing a cachebuster bypasses both pools, while changing only storage inputs
does not change a strong ETag for identical source bytes and processing intent.
Compute response ETags from the source byte seed and canonical output material,
never by hashing an encoded response body. Upstream ETags, especially weak ones,
are validation tokens, not automatically strong source byte identities.

A source record associates the input lookup identity with its byte version,
validators, policy evidence, and freshness timestamps. Retain sufficient version
and policy evidence with outputs to evaluate them safely when input blobs are
evicted. Metadata lookup and byte reads are separate operations. Metadata must
remain bounded and recoverable, rather than creating an unbounded third cache.
If evidence is missing, require source acquisition/validation before mutable
output reuse. Do not mistake an evicted input for proof that an output is stale
or invalid.

Cache records are external serialization boundaries and must be validated.
Do not persist credentials or emit source URLs/validator contents in telemetry.
Changing host policy reevaluates stored evidence under the current policy;
previously permissive settings cannot bypass newly restrictive configuration.

## Request lifecycle

Parsing, signature validation, and static request validation precede all cache
and source side effects. Source resolution then establishes the fetch identity
and host policy.

For trusted immutable identities, retain the early conditional fast path when
storage/HTTP policy can be determined without origin access. If origin storage
permission has never been established and is not explicitly overridden, acquire
the necessary origin evidence before claiming origin-respecting cache behavior.

For mutable identities, read version/freshness evidence before using an output
or answering a client conditional request. Classify it as fresh, stale but
servable, or requiring validation. An origin `304` updates applicable metadata
and retains the cached version. A changed `200` establishes the new byte version;
old outputs cannot be selected as representations of that new version.

When generation is required, look up the input bytes and otherwise fetch them.
Stage original encoded bytes to disk, preserving EXIF and ICC, and expose a
seekable file to decoding. Publish only complete successful transfers; cancellation,
oversize rejection, and errors release staged resources. Pin file resources for
the entire lazy processing lifetime. Apply current input generation limits on
input hits. Already-successful output hits retain existing generation-limit
semantics, and safety limits do not enter identities.

## Stale-while-revalidate

An eligible stale output is served immediately while a request-triggered,
supervised worker revalidates the source. Coalesce by source identity and storage
partition, then coalesce output rebuilds by variant. The refresh lifetime is
independent of the initiating connection, with bounded concurrency, deadlines,
cleanup, and retry backoff.

An unchanged source permits output reuse without re-encoding. A changed source
refreshes the requested output; other variants rebuild on demand. Version-aware
publication prevents a late old worker overwriting a newer generation. When the
stale window ends, requests wait for validation or receive the appropriate error.
Hits, unsuccessful refreshes, and regeneration from old input never extend it.

Initially, an output miss with only stale input waits for source validation
before generation. This keeps refresh ownership and deadlines explicit while
the two-pool lifecycle is introduced. Origin prohibitions apply unless the host
explicitly overrides them. `stale-if-error` requires its own policy and window;
SWR alone does not authorize extended error fallback.

Downstream headers, including conditional `304` responses, must preserve the
source-derived age and remaining reuse allowance. Generating a new derivative
from old input must not grant a new downstream freshness lifetime.

## Storage and delivery

Extract concrete filesystem storage/admission primitives from the current
response-specific adapter. Each pool owns its capacity, frequency sketch,
recency queues, admission state, and supervised maintenance. Input admission
records actual input demand and origin-fetch cost; output-only hits do not
increase input frequency. Account for staging and active readers explicitly.

Keep source adapters and source policy independent of cache storage and response
delivery. The request lifecycle coordinates these facades. Storage primitives
operate on owned storage descriptors, rather than importing source/response
orchestration structs. Update Boundary declarations with any extracted owner.

GitHub #40 belongs in this extraction: retain useful binary cache adapters while
adding a concrete file-backed read path. For the initial filesystem path, open
and pin a descriptor, validate metadata and byte size, and verify the stored
digest in bounded chunks before headers commit; rewind the same descriptor for
bounded delivery. This trades an extra sequential disk pass for bounded memory
and pre-header corruption detection. Enforce immutable published blobs and
coordinated eviction; document that uncontrolled external in-place mutation can
still cause mid-delivery failure, where regeneration is no longer possible.
Measure memory and I/O before considering a weaker integrity policy or sendfile.

## Execution and verification

Implement inline in the dependency order recorded in Beads, using test-first
vertical changes and a final independent review of each complete implementation
slice. Req RC migration and the cache sink-open failure fix are the first slice.
Policy/configuration and producer tests precede pool and request-lifecycle work;
keep unfinished behavior inaccessible until both cache paths are coordinated.

Each behavior ships with focused tests. The final wire matrix covers source and
output misses/hits, freshness transitions, `304`/changed origins, trusted sources,
overrides, cookie/Vary isolation, invalidation, partial files, cache failures,
coalesced refresh, eviction, and cancellation. Use controlled clocks and process
messages rather than sleep-based synchronization. Keep Logger and Trace.Capture
coverage synchronized with every event change.

The benchmark includes GitHub #273's region/tile workload, reporting origin
bytes, encoded storage, latency, decode shrink and memory high-water. Run the
repository gates through mise. Do not infer a useful capacity split from policy
correctness alone.
