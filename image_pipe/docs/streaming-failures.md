# Failures during streaming

ImagePipe sends a newly made image while it is still encoding it. The status
and headers go out with the first encoded bytes, and the rest of the image
follows as the encoder produces it. A `200` for a resized `cat.jpg` therefore
means the image started well, not that it will finish.

Only newly made images stream this way. Responses served from ImagePipe's
cache, and `info`, BlurHash, and CSS LQIP responses, are complete before
their headers are sent.

## Failures before headers

ImagePipe holds back the headers until the encoder has produced its first
bytes. Anything that fails before then gets a normal
[error response](errors.md), with a status and a short message. That covers
most failures:

- The URL doesn't parse, its signature is wrong, or it asks for something the
  deployment doesn't allow.
- The source is missing, or the origin fails or cuts its response short.
  ImagePipe downloads the whole original before the first bytes go out, so
  every fetch failure is reported this way.
- The original isn't an image ImagePipe can read, or exceeds a size limit.
- The [processing pool](processing-controls.md) is full, or the request waited
  too long for a slot.
- An operation that needs the whole image in memory, such as trim or rotating
  by an arbitrary angle, finds the file corrupt.
- The encoder fails before producing anything.

## Failures after headers

A few failures can only happen once the response is being sent:

- **Corrupt image data.** Pixels are decoded as the encoder needs them, so a
  file with a valid header and damaged data further in can fail halfway
  through the output.
- **Encoder errors** in the middle of the image.
- **The processing deadline** expires while the image is still streaming.
  [Processing deadline](#processing-deadline) below covers why.
- **No progress for 60 seconds.** ImagePipe waits at most that long for each
  encoded chunk.
- **A cached image can't be read** partway through, such as after a disk
  error.
- **The client disconnects.**

The status and headers have already been sent, so ImagePipe can't replace
them with an error. It stops sending and logs the failure.

## What the client receives

After any of these failures except a disconnect, the client has a `200` with
the right `Content-Type` and part of the image, and ImagePipe abandons the
response without finishing it:

- Over HTTP/1.1, the server closes the connection before the body is
  complete, so clients, proxies, and CDNs can tell it was cut short.
- Over HTTP/2, Bandit (the server behind `image_pipe_server` and new Phoenix
  apps) resets the stream, so the client sees the request fail.

A browser shows part of the image or a broken image.

ImagePipe raises `ImagePipe.Plug.StreamAbortedError` after logging the
failure, so the server logs that exception as well. Over HTTP/2 with Bandit it
raises `Bandit.HTTP2.Errors.StreamError` instead. In a Plug app, error
trackers that capture exceptions from your Plug pipeline report the exception
too.

## What the cache keeps

ImagePipe writes a new image to its cache while sending it, but only keeps it
when the encoder finished and every byte reached the client. A failure or
disconnect mid-stream leaves nothing in the cache, so the next request for the
same URL makes the image again. [Writing entries](cache.md#writing-entries)
lists the exact conditions.

Requests waiting for the same image don't receive a partial copy either. When
the image fails, each of them makes it again. When the client of the request
making it disconnects, one waiting request takes over.

## Client disconnects

With Bandit, ImagePipe notices that a client has gone the next time it
writes to the connection. It then stops the encoder and the work behind it,
releases the processing pool slot, and discards the partial cache entry.

When the client of a streamed image disconnects, ImagePipe logs it at `info`
level, not as an error, and the
[`[:deliver]` span](telemetry-events.md#deliver) ends with
`result: :client_closed`.

When the client has gone before ImagePipe sends the headers, Bandit raises
`Bandit.TransportError`. ImagePipe lets that exception reach Bandit, which
treats it as a client disconnect and by default doesn't log it. ImagePipe's
`[:send]` and `[:request]` spans end with the exception, so the
[default telemetry logger](telemetry.md#logging-with-the-default-logger) logs them as warnings. In a Plug app,
error trackers that capture exceptions from your Plug pipeline report it too.

The work stops between chunks, not instantly. A libvips operation that is
already running finishes first, and a stopped request gets one second to
clean up before it is killed.

## Processing deadline

With a processing pool, `processing_timeout` (default 30 seconds) limits how
long one request may hold a processing slot. It starts when the slot is
granted and runs until the last chunk has been sent, including the time spent
waiting for the client to accept data. A slow client can therefore make a
large image run out of time mid-stream. When the deadline expires, ImagePipe
stops the encoder, frees the slot, and ends the response as described above.
A request whose deadline expires before the first bytes go out gets a `503`
instead.

The deadline is set on the pool. See
[limiting concurrent processing](processing-controls.md) for Elixir and
[`[pool]`](../../image_pipe_server/docs/server-configuration.md#pool) for
`image_pipe_server`.

## Clients, proxies, and CDNs

Proxies and CDNs don't store a response whose body is incomplete. ImagePipe's
own cache never holds the partial copy either, so the next request gets a
complete image.
Settings that make truncation less likely are in
[slow clients](deployment.md#slow-clients).
