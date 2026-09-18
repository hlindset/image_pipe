# Execution flow

## Request lifecycle

`ImagePipe.Plug` validates mount configuration and delegates the request to
`ImagePipe.Plug.DialectRunner`. Native is the default API; imgproxy has its own
request adapter while its retained capabilities move to native.

The lifecycle is:

1. Parse and validate the request, including signatures, expiry, static geometry,
   and terminal applicability.
2. Resolve the source through the configured host source adapter.
3. Build the representation identity and negotiate output policy.
4. Apply the conditional request gate. A matching ETag can return 304 before
   source fetch, image decode, or cache access.
5. Look up a successful encoded response in the cache.
6. On a miss, fetch and decode the source, execute transforms, negotiate the
   final output against source facts, and encode.
7. Deliver the response, preserving streaming ownership and committing a cache
   entry only after successful generation.

Source, cache, detector, and telemetry exporter behaviours are host extension
points. Source adapters own fetch side effects and source byte identity;
representation code owns cache identity and validators; response code owns
headers and delivery.

## Native request and execution

`ImagePipe.Native.Parser` produces concrete native request data. Presets expand
before validation, and `then` separates explicitly ordered groups. Option order
inside a group does not affect processing order. The
[native API contract](native_api_contract.md) defines stages, coordinate frames,
and the capability inventory.

`ImagePipe.Native.Pipeline.decode_request/2` plans shrink-on-load from the first
group. Decode opens sequentially and supplies both image state and source
geometry. Only operations that need arbitrary pixel access materialize the
image, through `ImagePipe.Transform.Materializer`.

`ImagePipe.Native.Pipeline.run/4` imports input color profiles, executes groups,
flushes pending orientation, and stamps color state for the encoder. A group
applies rotation and flip, flushes pending orientation before trim, measures
the trimmed image, then resolves crop lengths in the resulting display frame.
Percentage lengths remain in effective source pixels
until lowering compensates for decode shrink.

Each group receives the preceding group's complete result. `orient=auto` applies
EXIF once; `orient=none` keeps stored pixels as the initial frame.
Deferred orientation composes successive rotations and flips while preserving
the same pixels as eager execution.

## Geometry and operations

The current native and imgproxy pipelines use semantic `Plan.Operation` values
and the shared `Transform.NeutralResolver`. The resolver produces executable
operations plus geometry updates. Source-dependent steps such as trim and
cover resizing measure the resulting image and continue from those dimensions.

`ImagePipe.Transform.Chain` executes concrete operation structs. Each operation
implements the transform behaviour; required materialization occurs immediately
before the first operation that needs it. `Transform.State` carries the image,
orientation, decode scaling, materialization, and color state.

Input color management and EXIF handling are fixed input conditioning.
Output format, quality, and profile policy belong to output negotiation and
encoding. Operation span durations measure lazy pipeline construction;
`[:transform, :execute]` is the aggregate transform stage.

## Delivery and terminals

`ImagePipe.Delivery.Producer` owns generation and its stream resources.
`ImagePipe.Response.Sender` sends the prepared response and stops production
when delivery is cancelled. Failed or incomplete streams do not enter cache.

Native BlurHash and imgproxy info responses use complete-body terminals.
Debug headers are request presentation: the mount must permit them, and the
request must opt in. They do not change image cache identity or the ETag.

See [cache behavior](cache.md), [HTTP caching](cdn-http-cache.md),
[debug headers](debug_headers.md), and [telemetry](telemetry.md) for their
respective contracts.
