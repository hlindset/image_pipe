# Shared execution and representation identity

Investigation: `image_plug-6z9.3`. Bug fix: `image_plug-6z9.3.1`.

## Responsibilities and boundaries

- `Plug.Runner` owns HTTP parsing, method/CORS handling, conditional requests,
  headers, and delivery. `Run` owns builder input/options and buffered native
  results. Both prepare requests before source access and call the same
  `Execution.prepare/open/close` lifecycle.
- `Processing.prepare/3` resolves output policy and checks expiry, encoder
  capability, and detector availability. Image processing produces a prepared
  stream through `Delivery`; fixed terminals use `Processing.Terminal` under the
  same admission pool. Download overlap resumes prepared pixels through the
  existing processing facade.
- `Execution.Context` carries request, resolved source, output policy, identity
  material, source acquisition, and config. `Acquisition` carries source record,
  response, lease, source bytes, and optional overlapped processing. These are
  internal concrete data, not extension protocols.
- `Execution.Inputs` validates native request headers/cookies and projects only
  configured storage inputs. HTTP uses Plug's parsed inputs. `Execution.Identity`
  combines groups, terminal policy, detector identity, and output selection;
  presentation/security-only fields stay out.
- `Representation` hashes the representation and source byte revision. Output
  storage additionally hashes storage-only inputs; ETags exclude them. Input
  keys use effective fetch context and storage partitioning, independently of
  transforms. Fetch context is digested before entering exposed key data.
- Host source adapters supply `CacheSemantics.byte_identity` as a stable,
  deterministic term. `Source` checks the tagged shape; it cannot establish
  semantic byte stability. `MaterialDigest` is the shared serialization/hash
  boundary for these terms.

## Priority 1: identity collisions and unsupported term seeds

`MaterialDigest.canonicalize/1` converted maps into sorted lists. Thus the valid
strong seeds `%{revision: 1}` and `[revision: 1]` produced identical hashes.
Sorting normalized compound map keys also erased meaningful differences between
distinct key/value assignments. Calling `Enum.map` on structs raised a protocol
error; improper-list seeds raised during traversal.

The wire regression uses a host source adapter returning red and blue PNGs with
map and list revision seeds. Before the fix, the second request reused the first
cached body and never fetched its source. A Date revision seed failed before
delivery. Digest examples/properties reproduced compound-key collisions and the
other term-shape failures independently.

Implemented `image_plug-6z9.3.1`:

- Preserve maps, their exact keys, and struct tags using `:maps.map/2`, while
  recursively normalizing values. Deterministic Erlang term serialization owns
  map ordering.
- Preserve proper and improper list structure; normalize keyword-list order as
  required by the existing identity contract.
- Keep SHA-256. A bounded 27/32-bit `phash2` value is insufficient as the sole
  storage key or validator: the cache does not disambiguate hash collisions by
  comparing original material.
- Replace a self-equality digest property with meaningful map/list separation
  coverage, and remove stale comments claiming structs cannot reach the digest.

This changes existing storage keys and ETags; affected cached outputs are
regenerated. Internal schema versions remain unchanged under the greenfield
cache policy. The storage-only/ETag distinction, conditional fast path, and
byte-identity requirements remain intact.

## Retained design

- **One lifecycle, two result consumers.** HTTP can stream or return a pre-fetch
  304; native callers need a buffered `Result`. Their frontend-specific wrappers
  are small and justified. Source info must decode cached JSON at the native
  boundary, while image dimensions can reuse debug metadata or decode bytes.
- **Separate lease lifetimes.** `prepare` owns its acquisition lease through the
  conditional gate. `open` can acquire another lease after a stale/missing input;
  `Output.extra_lease` releases it after consumption. Streaming output-work leases
  belong to delivery, whereas complete bodies finish immediately. Collapsing
  these into one generic resource wrapper risks early release or leaks.
- **Explicit cleanup paths.** `generate_leased`, `open_with_lease`, output closing,
  and refresh closing cover different ownership transitions. Similar catch/after
  blocks are not sufficient evidence for a callback-based cleanup framework.
- **Cache-entry boundary checks.** Terminal versus image entries are checked
  after external cache lookup and incompatible entries are closed. This is real
  external-storage validation and remains necessary.
- **Stale handling.** Fresh representations can answer conditional requests;
  stale hits schedule refresh and misses acquire current source data. The
  background refresh uses the same open/consume/close path. Freshness policy and
  work coordination receive their deeper review in `6z9.12`.
- **Identity ownership.** Output negotiation stays in Output, source revision
  facts stay in Source, and Execution combines their public facts. Safety limits
  gate generation without fragmenting successful cached representations. Keep
  source concealment and redacted context inspection.

No additional orchestration rewrite is recommended. The identity bug is the
highest-priority finding and its implementation is isolated from cache freshness,
admission, buffering, and transport behavior.

## Validation

Before the fix, map/list separation, compound-key separation, struct seeds, and
real source cache behavior failed. The additional improper-list regression also
failed before its fix. After the fix, the focused native/HTTP identity, cache,
conditional, terminal, and coordinated-cache suite passed 143 checks; the final
digest and source-identity wire suite passed all 13 checks.

Full `mise run precommit` passed: formatting, warnings-as-errors compilation,
Credo, Dialyzer, duplication analysis, and 2,533 tests/properties, with 5 optional
integration exclusions.
