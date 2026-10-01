# Deployment

Configure source limits, generation capacity, and HTTP timeouts for your workload.

## Streaming failures

ImagePipe pulls the first encoded chunk before sending headers, so an early
failure can return a normal [error response](errors.md). Later source, decode,
encode, or client-close failures stop delivery and discard partial cache writes.
Cache errors fail open: delivery continues and telemetry records the failure.
A started response cannot be replaced with a new status or error body.

## Resource limits and timeouts

HTTP and S3 sources enforce redirect and receive-timeout limits. ImagePipe
identifies formats from image bytes rather than HTTP headers. Header inspection
rejects oversized inputs early where possible; decoded dimensions are always
checked before transforms.
See [resource limits](configuration.md#resource-limits) for defaults and
configuration.

Source adapter limits bound fetches per chunk and by total bytes.
`:receive_timeout` limits waits between chunks;
`:connect_timeout` and `:pool_timeout` bound connection setup and checkout.
`:max_body_bytes` limits total size. Use a front proxy or CDN to bound waits
for ImagePipe's response and handle slow clients:

- A trickling origin can keep a transfer open by sending each chunk just before
  `:receive_timeout`. Configure a total request deadline in your hosting layer
  as well as per-chunk timeouts.
- A slow-reading client that drains a chunked response one TCP window at a time
  keeps generation resources occupied. Response
  buffering lets a proxy drain ImagePipe promptly and feed the client itself;
  the proxy's send timeout then bounds the client. Without a proxy, configure
  the server's outbound write or idle timeout.

An optional [processing pool](processing-controls.md) caps concurrent generation
and queued jobs across Plug and Elixir callers. Its processing deadline covers
admitted generation through stream cleanup, including source consumption and
downstream demand pauses. Source-cache acquisition and revalidation before the
output-cache lookup retain their independent source limits. Output-cache hits
and conditional responses bypass processing admission.

Input body, pixel, and frame limits reject oversized sources with `413`.
Output limits instead downscale the final image uniformly before encoding.
Generation limits do not change cache identity: a successful cached response
can still be served after limits are lowered.

## Memory

Decode uses sequential access and JPEG shrink-on-load or WebP scale hints
where geometry permits. Operations that need random pixel access copy the
image into RAM; orientation flushes and delivery can also allocate buffers.
Allow memory for these copies across concurrent requests.
