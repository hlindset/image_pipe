# Execution flow

## Request lifecycle

`ImagePipe.Plug` validates mount configuration and delegates the request to
`ImagePipe.Plug.Runner`, which handles parsing, conditional responses, and HTTP
delivery. `ImagePipe.run/3` validates the builder's plan and host configuration,
resolves its input, and returns a fully consumed result. Both use
`ImagePipe.Execution` for source freshness, cache lookup, and generation.

The lifecycle is:

1. Parse and validate the request, including signatures, expiry, static geometry,
   terminal applicability, and output capabilities. Combine request output
   options, host defaults, and Accept negotiation into `ImagePipe.Output.Policy`.
2. Resolve the source through the configured host source adapter.
3. Resolve source freshness and build representation identity from the current
   source byte identity and output policy. Remote sources may need revalidation.
4. HTTP applies its conditional request gate. Once source freshness is known,
   a matching ETag can return 304 before image decode or output-cache access.
   Trusted identities also permit this gate without a source fetch.
5. Look up a successful encoded response in the cache.
6. On a miss, fetch and decode the source, execute transforms, negotiate the
   final output against source facts, and encode.
7. Deliver the response, preserving streaming ownership and committing a cache
   entry only after successful generation.

Source, cache, detector, and telemetry exporter behaviours are host extension
points. Source adapters own fetch side effects and source byte identity;
representation code owns cache identity and validators; response code owns
headers and delivery.

## Request and execution

`ImagePipe.API.Parser` produces `ImagePipe.Plan.Request` data. Presets expand
before validation, and `then` separates explicitly ordered groups. Option order
inside a group does not affect processing order. The
[API contract](api_contract.md) defines stages, coordinate frames,
and the capability inventory.

`ImagePipe.Transform.Executor.decode_request/2` plans shrink-on-load from the first
group. Decode opens sequentially and supplies both image state and source
geometry. Only operations that need arbitrary pixel access materialize the
image, through `ImagePipe.Transform.Materializer`.

`ImagePipe.Transform.Executor.execute/3` imports input color profiles, executes groups,
flushes pending orientation, and returns image and color state. Processing passes
the retained source ICC profile directly to the encoder. A group
applies rotation and flip, flushes pending orientation before trim, measures
the trimmed image, then resolves crop lengths in the resulting display frame.
Percentage lengths remain in effective source pixels
until geometry resolution compensates for decode shrink.

Each group receives the preceding group's complete result. `orient=auto` applies
EXIF once; `orient=none` keeps stored pixels as the initial frame.
Deferred orientation composes successive rotations and flips while preserving
the same pixels as eager execution.

## Geometry and operations

The executor reads validated group fields and constructs concrete
transform operations. Source-dependent steps such as trim and cover resizing
measure the resulting image before resolving the next stage. Runtime geometry,
orientation, and decode scaling live in `Transform.State`.

The executor calls `ImagePipe.Transform.run/3` for each operation. This shared
runner handles telemetry, errors, and materialization before an operation needs
random access. `Transform.State` carries the image, orientation, decode scaling,
materialization, and color state.

Input color management and EXIF handling are fixed input conditioning.
Output format, quality, and profile policy belong to output negotiation and
encoding. Operation span durations measure lazy pipeline construction;
`[:transform, :execute]` is the aggregate transform stage.

## Delivery and terminals

`ImagePipe.Delivery.Producer` owns generation and its stream resources.
`ImagePipe.Response.Sender` sends the prepared response and stops production
when delivery is cancelled. Failed or incomplete streams do not enter cache.

`Processing.Terminal` renders BlurHash, LQIP CSS, and info as complete-body responses.
It owns their decode resources and terminal telemetry. BlurHash and LQIP CSS run the
executor and terminal reduction; info reports decoded source facts without
transforming pixels.
Shared execution stores their encoded representations. Native calls consume
the same entries and deserialize info into a map. Background stale refresh
drains output through shared execution, without an HTTP connection.
Debug headers are request presentation: the mount must permit them, and the
request must opt in. They do not change image cache identity or the ETag.

See [cache behavior](cache.md), [HTTP caching](cdn-http-cache.md),
[debug headers](debug_headers.md), and [telemetry](telemetry.md) for their
respective contracts.
