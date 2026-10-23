# Error responses

ImagePipe answers every failure that happens before response headers are sent
with a status and a short `text/plain` message. A failure after headers have
been sent abandons the response before it is complete instead, as described
in [failures during streaming](streaming-failures.md).

Errors never become cache entries. [Telemetry](telemetry.md) events carry more
detail than the response, which deliberately says less.

## How statuses are chosen

- **4xx** means the request can't succeed as written against this deployment:
  the URL is malformed or unauthorized, the source doesn't exist, or the source
  isn't an image ImagePipe will process.
- **5xx** means ImagePipe, its host configuration, or the origin failed. The
  same request may succeed later or on another deployment, so the response
  carries `Cache-Control: no-store`.
- **Sources are concealed.** A client learns that a source wasn't found,
  couldn't be processed, or that the origin failed. It never learns an origin's
  status code, whether ImagePipe's credentials were rejected, or which of
  the source's path or network rules refused the request. Those all read as
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
| `400` | The URL doesn't parse, fails validation, or names a source scheme that no configured source serves. Validation fails for `sig` on a server without signing keys, `enc/` or `wm-enc` on a server without source encryption keys, or a `detect` class that the configured detector doesn't support. The body lists the problems. A source that doesn't parse or that no source serves gets the body `invalid source`, and output options that can't be combined get `invalid output`. |
| `403` | A required signature is missing or wrong. The body is always `invalid signature`. |
| `404` | No key on the server decrypts an encrypted source token in the URL. |
| `405` | The method isn't `GET`, `HEAD`, or `OPTIONS`. The response carries `Allow`. |
| `410` | The request's `expires` time has passed. |
| `500` | A [stored preset](storing-presets-in-a-database.md) is broken: it doesn't parse, names an unknown preset or watermark, sets options that can't be combined, or has a `wm-enc` token that no source encryption key decrypts. |
| `501` | Detection was requested, the configuration requires it, and the detector can't detect the requested classes in this build. When detection isn't required, such requests [fall back to attention cropping](content-aware-gravity.md#missing-or-failed-detection). |
| `503` | The preset lookup is unavailable, or detection was requested, the configuration requires it, and the detection models aren't downloaded yet. |

All of these return before source resolution, fetch, or cache access.

### Source

| Status | When |
| --- | --- |
| `404` | Nothing exists at the source path, or the source's rules refuse it: a path that doesn't match the source's allowed paths, a denied host, address, scheme, or bucket, a host that doesn't resolve, a directory where a file was expected. Also when the origin answers `401`, `403`, `404`, or `410`. |
| `413` | The source body exceeds `max_body_bytes`. |
| `500` | A local file or a cached original exists but can't be read, source credentials are unavailable, or a custom source adapter returns an invalid result. |
| `502` | The origin is unreachable, answers any other error status, redirects badly, or sends a truncated or malformed response. |
| `504` | The origin doesn't answer in time, no connection to it frees up within the source's `pool_timeout`, or a request runs out of time while a request for another size or format downloads the same original, or while another request checks it with the origin (see [coordination limits](cache.md#coordination-limits)). |

### Decode and processing

| Status | When |
| --- | --- |
| `400` | The request's geometry is impossible for this image, such as a crop region outside it. |
| `413` | The decoded image exceeds `max_input_pixels` or declares more frames than allowed. |
| `415` | The source isn't a supported image. |
| `422` | The transform can't be applied to this image, its dimensions exceed a native limit, a frame exceeds `max_intermediate_pixels` when buffered, downsampled, or delivered, the request's blurs and sharpens exceed `max_blur_work`, or the requested page doesn't exist. |
| `500` | Encoding failed, detection failed and the configuration requires it, or an unexpected internal error occurred. |
| `501` | The requested output format has no encoder in this build. |
| `503` | Processing is overloaded, queued too long, unavailable, or exceeded its deadline. An overloaded or queued-too-long response has a `Retry-After` header. |
