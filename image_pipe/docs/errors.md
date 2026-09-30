# Error responses

ImagePipe answers every failure that happens before response headers are sent
with a status and a short `text/plain` message. A failure after streaming
headers have been sent ends the stream instead; see
[processing limits](processing-controls.md#failure-and-cancellation).

Errors never become cache entries. [Telemetry](telemetry.md) events carry more
detail than the response, which deliberately says less.

## How statuses are chosen

- **4xx** means the request can't succeed as written against this deployment:
  the URL is malformed or unauthorized, the source doesn't exist, or the source
  isn't an image ImagePipe will process.
- **5xx** means ImagePipe, its host configuration, or the origin failed. The
  same request may succeed later or on another deployment.
- **Sources are concealed.** A client learns that a source wasn't found,
  couldn't be processed, or that the origin failed. It never learns an origin's
  status code, whether ImagePipe's credentials were rejected, or which part of
  a mount's path or network policy refused the request. Those all read as
  `404 source not found`.
- **One failure, one status.** A source that's too large gets `413` whether the
  limit is on its bytes, its pixels, or its frames.
- **Missing capability is `501`.** A well-formed request for something this
  deployment isn't built or configured to do, such as an output format without
  an encoder or detection without a detector, may succeed elsewhere.

## Status table

### Request

| Status | When |
| --- | --- |
| `400` | The URL doesn't parse or fails validation, including `sig` on a mount without signing keys. The body lists the problems. |
| `403` | A required signature is missing or wrong. The body is always `invalid signature`. |
| `404` | An encrypted source token fails to decrypt. |
| `405` | The method isn't `GET`, `HEAD`, or `OPTIONS`. The response carries `Allow`. |
| `410` | The request's `expires` time has passed. |

All of these return before source resolution, fetch, or cache access.

### Source

| Status | When |
| --- | --- |
| `404` | Nothing exists at the source path, or the mount's policy refuses it: a path outside `path_pattern`, a denied host, address, scheme, or bucket, a directory where a file was expected. Also when the origin answers `401`, `403`, `404`, or `410`. |
| `413` | The source body exceeds `max_body_bytes`. |
| `500` | A local file exists but can't be read, source credentials are unavailable, or a source adapter is misconfigured. |
| `502` | The origin is unreachable, answers any other error status, redirects badly, or sends a truncated or malformed response. |
| `504` | The origin doesn't answer in time. |

### Decode and processing

| Status | When |
| --- | --- |
| `400` | The request's geometry is impossible for this image, such as a crop region outside it. |
| `413` | The decoded image exceeds `max_input_pixels` or declares more frames than allowed. |
| `415` | The source isn't a supported image. |
| `422` | The transform can't be applied to this image, or the requested page doesn't exist. |
| `500` | Encoding failed, or an unexpected internal error occurred. |
| `501` | The requested output format has no encoder in this build, or detection was requested with `detector_required: true` and no detector is available. |
| `503` | Processing is overloaded, queued too long, unavailable, or exceeded its deadline. |

## Custom source adapters

A source adapter returns `{:error, {:source, reason}}`. The built-in reasons
above map as listed. Any other reason is treated as an origin failure and
answers `502`.

To choose a different status, lead the reason with a status class:
`{:error, {:source, {class, detail}}}`, where `class` is one of `:bad_request`
(`400`), `:not_found` (`404`), `:payload_too_large` (`413`),
`:unsupported_media` (`415`), `:server_error` (`500`), `:not_implemented`
(`501`), `:bad_gateway` (`502`), or `:gateway_timeout` (`504`). The detail is
free-form and never reaches the response body.
