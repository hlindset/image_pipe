# Caching and freshness

ImagePipe can keep two caches: one for originals fetched from your sources, and
one for processed images. A resized `cat.jpg` has no expiry time of its own.
It stays valid as long as the original `cat.jpg` it was made from is up to
date, so every size and format made from `cat.jpg` expires when the original
does, and one request to the origin checks them all.

Both caches, and the settings on this page, are host configuration, set for
all sources or per source. Request URLs can't change them:

- In Elixir, [Cache](cache.md) sets up the caches. The settings are in
  [freshness and source stability](cache.md#freshness-and-source-stability),
  `ImagePipe.Source.CachePolicy`, and [local files](sources.md#local-files).
- In `image_pipe_server`, see
  [server configuration](https://github.com/hlindset/image_pipe/blob/main/image_pipe_server/docs/configuration.md):
  the `[cache]` table sets up the caches, and the settings are under
  `[processing]` and each `[sources.<name>]` table.

## Originals and processed images

Each processed image belongs to one version of its original. A version is
identified by the original's content, or for a write-once source by its path,
URL, or S3 version.

- When the origin starts serving different bytes for `cat.jpg`, requests make
  new processed images from the new version. Copies made from the old bytes
  are never served again, and stay in the cache until they are evicted.
- When a check finds the same bytes, the existing processed images are reused
  without processing anything. This holds for a `304` and for a full download
  that turns out identical.
- Processed images can still be served after the original has been evicted
  from the originals cache.

## Cache lifetime from origin headers

The originals cache reads `Cache-Control`, `Expires`, `Date`, and `Age` as a
shared cache does under [RFC 9111](https://www.rfc-editor.org/rfc/rfc9111).

- If the origin sends no lifetime, ImagePipe checks with the origin on every
  request. It never guesses a lifetime from `Last-Modified`. A fallback
  lifetime, if you set one, applies only to origins that send none.
- A forced lifetime replaces whatever the origin sends, including `no-cache`.
- The lifetime counts from the origin's response.

An origin that sends no `ETag` or `Last-Modified` gets a full download on
every check, though processed images are still reused when the bytes are
unchanged.

How these lifetimes reach browsers and CDNs is covered in
[Serving images through a CDN](serving-through-a-cdn.md) and
[HTTP and CDN caching](cdn-http-cache.md).

## Stale-while-revalidate

Once an original's lifetime runs out, the origin's `stale-while-revalidate`
window lets the cache serve a stale processed image while the original is
checked:

- A processed image that is already cached is served at once, and the
  original is checked in the background. If the original changed, other sizes
  are made from the new version when they are next requested.
- A size that isn't cached yet waits for the check.

After the window ends, the original is checked before anything is served. If
that check fails, the client gets the error. ImagePipe doesn't implement
`stale-if-error`.

An origin `must-revalidate`, `proxy-revalidate`, `s-maxage`, or `no-cache`
turns the origin's window off. You can turn the window off for a source, or
force one, which applies even when the origin sends `must-revalidate`. When
too many background checks are already running, the stale image is still
served, and a later request starts the check.

## Storage permission

By default ImagePipe follows the origin: `no-store` or `private` means neither
the original nor its processed images are stored, and the response carries
`Cache-Control: no-store`. Fetches that use your source credentials, such as
signed S3 requests, follow the same rules. An origin `no-transform` doesn't
stop requested processing or change storage permission.

You can allow storage for a source, which overrides `no-store` and `private`,
or deny it. `Vary: *` from the origin prevents storage even when it is
allowed. A forced lifetime doesn't make a `no-store` response storable.

## Write-once sources

For write-once storage, content-addressed paths, or storage where your
application never replaces a file in place, you can mark a source as one whose
files never change. Originals and processed images from that source never
expire and are never checked, so a cached `cat.jpg` is served without
contacting the source. They can still be evicted, and still need permission
to be stored.

Such a source can't have its own lifetime or stale window, and a default
lifetime set for all sources doesn't apply to it. S3 identifiers that name an
object version are treated as write-once automatically (see
[S3-compatible storage](sources.md#s3-compatible-storage)).

## Local file sources

A local file has no origin headers, so it has no lifetime unless you set a
fallback one. Unless the source is write-once, the file source identifies each
file by its content: a changed `cat.jpg` gets new processed images, and an
unchanged one reuses them.

Each request checks the file's size and timestamps, and reads the file again
only when they have changed. Where file times can't be trusted, the source can
read and hash the file on every check instead. With a fallback lifetime,
requests within it skip the check.

Originals are read where they are. On a network filesystem, the source can
keep a local copy in the originals cache, so other sizes don't read the file
over the network again.

## Request coalescing

When many requests for a new processed image arrive at once, the image is
made once and sent to all of them. This needs a processed-image cache, and
applies only to images that may be stored. Requests for different sizes of one
original share one check with the origin when a cache is configured, and one
download when an originals cache is configured.

Both kinds of sharing are local to each node, so two servers can still make
the same image. If the image isn't in the cache when the first request
finishes, because processing failed or the image was too large to store, each
waiting request makes the image itself. When too many requests are already
waiting, new ones go ahead without waiting. The limits are listed in:

- Source fetches and background checks:
  [coordination limits](cache.md#coordination-limits).
- Processed images: [request coalescing](processing-controls.md#output-cache-request-coalescing),
  next to the processing pool limits that still apply.
