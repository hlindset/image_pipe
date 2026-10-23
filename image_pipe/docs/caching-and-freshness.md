# Caching and freshness

A resized `cat.jpg` has no expiry time of its own. It stays valid as long as
the original `cat.jpg` it was made from is up to date, so every size and
format made from `cat.jpg` expires when the original does, and one request to
the origin checks them all.

The cache, and the settings on this page, are host configuration, set for
all sources or per source. Request URLs can't change them:

- In Elixir, the `cache` option sets up the cache, with the options listed
  in `ImagePipe.Cache.FileSystem`. The settings
  are in [source cache settings](cache.md#source-cache-settings) and
  `ImagePipe.Source.File`.
- In `image_pipe_server`, see
  [server configuration](../../image_pipe_server/docs/server-configuration.md):
  the `[cache]` table sets up the cache, and the settings are under
  `[processing]` and each `[sources.<name>]` table.

## Originals and processed images

Each processed image belongs to one version of its original. Most sources
identify a version by the original's content. An
[immutable source](#immutable-sources) identifies it by the original's path,
URL, or S3 object instead. A source's name isn't part of the version, so
renaming a source keeps its processed images. Two configured sources that
read the same original share its processed images when its content matches.
Immutable sources share them only when their settings match too.

- When the origin starts serving different bytes for `cat.jpg`, requests make
  new processed images from the new version. Copies made from the old bytes
  are never served again. The cache evicts them as it needs space (see
  [size limit](cache.md#size-limit)).
- When a check finds the same bytes, the existing processed images are reused
  without processing anything. This holds for a `304` and for a full download
  that turns out identical.

Unless the source is [immutable](#immutable-sources), an instance remembers
each original's content hash in memory to find its processed images,
together with the origin's cache headers or a local file's size and
timestamps. It remembers one original for each 50 KB of the processed-image
cache's size, at least 10,000 and at most 200,000, and forgets originals
that weren't used recently first. The limit is `max_remembered_originals` in
`ImagePipe.config/1`, or
[`[cache] max_remembered_originals`](../../image_pipe_server/docs/server-configuration.md#cache)
on the server.

After a restart, or once an original is forgotten, its next request
downloads it from the origin, or reads and hashes the local file, before
its processed images can be served.

## Cache lifetime from origin headers

ImagePipe reads an original's `Cache-Control`, `Expires`, `Date`, and `Age`
as a shared cache does under
[RFC 9111](https://www.rfc-editor.org/rfc/rfc9111).

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
[HTTP cache headers](cdn-http-cache.md).

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

## Immutable sources

For write-once storage, content-addressed paths, or storage where your
application never replaces a file in place, you can mark a source as one whose
files never change. Originals and processed images from that source never
expire and are never checked, so a cached `cat.jpg` is served without
contacting the source. They can still be evicted, and still need permission
to be stored.

An immutable source identifies each version by where the original comes from,
not by its content:

- A local file by the source's `root_id`, a stable name for its directory
  (see [add a file source](serving-local-files.md#add-a-file-source)), and the file's path.
- An HTTP original by its URL, including the query string.
- An S3 object by its endpoint, bucket, key, and version ID.

Changed content must therefore get a new identifier, such as `cat-v2.jpg`.
For HTTP and S3 sources, changing how the source fetches originals, such as
its request options or credentials, also gives every original a new version.
Credentials are hashed first, so they never appear in cache keys or `ETag`s.

An immutable source can't have its own lifetime or stale window, and a default
lifetime set for all sources doesn't apply to it. S3 identifiers that name an
object version are treated as immutable automatically (see
[request object versions](serving-from-s3.md#request-object-versions)).

## Local file sources

A local file has no origin headers, so it has no lifetime unless you set a
fallback one. Unless the source is immutable, the file source identifies each
file by a hash of its content: a changed `cat.jpg` gets new processed images,
and an unchanged one reuses them.

Each request checks the file's size and timestamps, and reads the file again
only when they have changed, after a restart, or once the file is forgotten
(see [originals and processed images](#originals-and-processed-images)).
Where file times can't be trusted, the source can read and hash the file on
every check instead. With a fallback lifetime, requests within it skip the
check. The file is always read where it is.

The cache identifies files by the source's `root_id` and their path, not by
the directory's `root`. Moving the directory to a new `root` keeps processed
images and their `ETag`s, as long as `root_id` stays
the same. Two file sources with the same `root_id` share these entries, so
they must use the same `root`. Otherwise the configuration fails to load.

## Request coalescing

When many requests for a new processed image arrive at once, the original is
downloaded once, and the image is made once and sent to all of them. This
needs a processed-image cache, and applies only to images that may be stored.
Requests for different sizes or formats of an original from an HTTP or S3
source share its download while it runs, with or without a cache, and so do
requests that check a previously downloaded original with its origin. When
[caching is turned off](cache.md#source-cache-settings) for the source,
nothing is shared.

All of this sharing is local to each node, so two servers can still make the
same image. A waiting request stops waiting and does the work itself:

- When the first request fails, or its image isn't stored.
- When a watermark asset may not be stored, which keeps the image from being
  stored too. Waiting requests start once the first request has downloaded
  the original.
- When the original [may not be stored](#storage-permission), as soon as the
  origin responds.
- When the image is too large to store or
  [detection failed](cache.md#what-is-stored), as soon as the server finds
  out.

When too many requests are already waiting, new ones go ahead without
waiting. Waits are also limited in time. The limits are listed under
[coordination limits](cache.md#coordination-limits).

A [low-priority request](processing/request.md#priority) waits for a normal
request that is making the same image. Otherwise it makes the image itself,
and no other request waits for it.
