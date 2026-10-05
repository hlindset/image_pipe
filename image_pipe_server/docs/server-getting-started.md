# Getting started with the server

In this guide we'll run `image_pipe_server` in Docker, point it at a folder
of photos on your machine, and open resized, cropped, and converted copies of
a photo in the browser.

You need Docker, port 8080 free, and a JPEG photo.

## Getting the server image

```bash
docker pull ghcr.io/hlindset/image_pipe_server:0.1.0
```

## Adding a folder of images

The server reads originals from a folder and makes processed copies of them
on request. Let's create a working directory with an
`images` folder:

```bash
mkdir -p image-server/images
cd image-server
```

Copy any JPEG photo into `images` as `photo.jpg`:

```bash
cp /path/to/your/photo.jpg images/photo.jpg
```

The examples below use a 4000×2667 photo. With your photo, the widths match
and the heights follow its proportions.

## Writing the configuration

Next, we tell the server where the originals are. Create `config.toml` in the
`image-server` directory:

```toml
# config.toml
[sources.photos]
adapter = "file"
match = "path"
root = "/data/images"
root_id = "photos"
```

This defines one source named `photos`. A source is a place the server reads
originals from:

- `adapter = "file"` reads files from a directory.
- `match = "path"` sends every image path in a URL to this source.
- `root` is that directory, as the server sees it inside the container. We
  mount our `images` folder there in the next step.
- `root_id` is a stable name for this directory.

## Starting the server

Let's start the server in the background, with our configuration file and
our `images` folder mounted at the paths in `config.toml`:

```bash
docker run -d --name image-server -p 8080:8080 \
  -v "$PWD/config.toml:/etc/image_pipe/config.toml:ro" \
  -v "$PWD/images:/data/images:ro" \
  ghcr.io/hlindset/image_pipe_server:0.1.0
```

The server reads `/etc/image_pipe/config.toml` at startup. Open
<http://localhost:8080/health/ready> in your browser. Within a second or two it
shows:

```text
ok
```

If the page doesn't load, the server didn't start. A mistake in
`config.toml` stops it. Check its log:

```bash
docker logs image-server
```

The log ends with a line that names the setting. Leaving out `match`, for
example, ends the log with:

```text
invalid configuration: sources.photos.match: required
```

Fix `config.toml`, remove the stopped container with
`docker rm image-server`, and run the `docker run` command again.

## Resizing an image

An image URL lists processing options, then `src/`, then the image's path in
the source. Let's ask for `photo.jpg` at 400 pixels wide. Open this URL:

<http://localhost:8080/w=400/src/photo.jpg>

```text
GET /w=400/src/photo.jpg (in Chrome)
200 OK, content-type: image/avif, 400×267
```

The browser's tab title shows the size, `400×267`. Notice that:

- `src/photo.jpg` is `/data/images/photo.jpg` in the `photos` source, which is
  `images/photo.jpg` on your machine. A photo in a subfolder,
  `images/trips/beach.jpg`, is `src/trips/beach.jpg`.
- `w=400` sets only the width. The height follows the photo's proportions.
- The original is a JPEG, but Chrome got AVIF, as its developer tools show.
  Without a `format` option, the server picks AVIF or WebP when the browser
  accepts it. Browsers that don't ask for AVIF or WebP, such as Safari and
  Firefox, get a JPEG, so the results below show `image/jpeg` there.

Now change `w=400` to `w=800`:

<http://localhost:8080/w=800/src/photo.jpg>

```text
GET /w=800/src/photo.jpg
200 OK, content-type: image/avif, 800×533
```

Files you add to `images` can be requested right away, without restarting
the server.

If a request fails, the status and body say why:

- `404` with `source not found`: the file name is mistyped.
- `400` with `invalid transformation options`: the URL leaves out `src/`, as
  in `/w=400/photo.jpg`. The body ends with
  `missing src/, src64/, or enc/ before the image path`.
- `500` with `source unavailable`: the server can't read the file, for
  example because only your user can read it. Make it readable with
  `chmod a+r images/photo.jpg`.

## Fitting an image in a box

With both a width and a height, the server fits the photo inside that box:

<http://localhost:8080/w=300/h=300/src/photo.jpg>

```text
GET /w=300/h=300/src/photo.jpg
200 OK, content-type: image/avif, 300×200
```

Notice that the result is 300×200, not 300×300. By default the whole photo
stays visible, so the wide photo fills the box's width and leaves its height
short. Add `fit=cover` to fill the box instead:

<http://localhost:8080/w=300/h=300/fit=cover/src/photo.jpg>

```text
GET /w=300/h=300/fit=cover/src/photo.jpg
200 OK, content-type: image/avif, 300×300
```

The photo now covers the whole 300×300 square, and the parts that don't fit
are cropped off both sides, keeping the center.

The order of options doesn't matter: `fit=cover/h=300/w=300` gives the same
image. An unknown value gets a `400`, and the body points at the problem.
With `fit=fill`:

```text
invalid transformation options

/w=300/h=300/fit=fill/src/photo.jpg
                 ^^^^
                 |
                 invalid value: expected contain, cover, stretch, or auto
```

## Choosing the output format

To get the same format whatever the browser accepts, add `format`:

<http://localhost:8080/w=300/h=300/fit=cover/format=png/src/photo.jpg>

```text
GET /w=300/h=300/fit=cover/format=png/src/photo.jpg
200 OK, content-type: image/png, 300×300
```

`format` also takes `webp`, `avif`, and `jpeg`.

When you're done, stop and remove the container:

```bash
docker rm -f image-server
```

## Next steps

We ran the server against a folder of originals and requested resized,
cropped, and converted copies by URL. From here:

- [Requesting images](../../image_pipe/docs/requesting-images.md): how URLs
  are built, option values, presets, and error responses.
- [Resize and layout](../../image_pipe/docs/processing/resize.md): every
  `fit` mode, pixel density, and padding. The
  [processing options](../../image_pipe/docs/processing.md) page lists the
  other categories.
- [Configuring image_pipe_server](server-configuration.md): environment
  variables and every setting in `config.toml`, including HTTP and S3
  sources.
- [Deploying image_pipe_server](server-deployment.md): caches, a read-only
  filesystem, health checks, Docker Compose, and Kubernetes.

Before exposing the server, set up URL signing with the
[`[url]` keys](server-configuration.md#url) setting.
[Building URLs for the server](../../image_pipe/docs/building-server-urls.md)
shows the application side, which signs the URLs.
