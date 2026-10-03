# Getting started with Phoenix

In this guide we'll add ImagePipe to a new Phoenix app, serve resized and
cropped copies of a photo from it, and show one on a page.

You need Elixir 1.18 or newer, the Phoenix installer (`mix archive.install
hex phx_new`), and a JPEG photo.

## Creating the app

```bash
mix phx.new gallery --no-ecto --install
cd gallery
```

Add ImagePipe to the dependencies in `mix.exs`:

```elixir
# mix.exs
defp deps do
  [
    {:image_pipe, "~> 0.1.0"},
    # ...the generated dependencies
  ]
end
```

ImagePipe needs a newer `req` than a new Phoenix app locks, so we unlock it
before fetching:

```bash
mix deps.unlock req
mix deps.get
```

Without the unlock, `mix deps.get` stops with a version conflict over `req`.

## Adding a folder of photos

ImagePipe reads originals from a folder and makes processed copies of them on
request. Create `priv/photos` and copy your photo into it as `photo.jpg`:

```bash
mkdir -p priv/photos
cp /path/to/your/photo.jpg priv/photos/photo.jpg
```

The examples below use a 4000×2667 photo. With your photo, the widths match
and the heights follow its proportions.

## Starting ImagePipe

Next, we start ImagePipe in the app's supervision tree and tell it where the
originals are. Add it to the children in `lib/gallery/application.ex`, before
the endpoint:

```elixir
# lib/gallery/application.ex
children = [
  # ...
  {ImagePipe,
   name: Gallery.Images,
   sources: [
     photos: [
       adapter: ImagePipe.Source.File,
       match: :path,
       options: [root: Application.app_dir(:gallery, "priv/photos"), root_id: "photos"]
     ]
   ]},
  # Start to serve requests, typically the last entry
  GalleryWeb.Endpoint
]
```

This starts an ImagePipe instance named `Gallery.Images` with one source
named `photos`. A source is a place ImagePipe reads originals from:

- `adapter: ImagePipe.Source.File` reads files from a directory.
- `match: :path` sends every image path in a URL to this source.
- `root` is that directory, `priv/photos` in our app.
- `root_id` is a stable name for this directory.

## Mounting the Plug

`ImagePipe.Plug` answers image requests for the instance. Add a `forward` to
`lib/gallery_web/router.ex`, outside the `:browser` scope:

```elixir
# lib/gallery_web/router.ex
forward "/media", ImagePipe.Plug, instance: Gallery.Images

scope "/", GalleryWeb do
  pipe_through :browser

  get "/", PageController, :home
end
```

Image requests don't need the session, CSRF protection, or HTML layout of the
`:browser` pipeline. We use `/media` rather than `/images` because a new
Phoenix app already serves its static files under `/images`.

## Resizing an image

Start the app:

```bash
mix phx.server
```

If it stops at startup with an `ArgumentError`, the message names the
setting to fix in `application.ex`.

An image URL lists processing options, then `src/`, then the image's path in
the source. Let's ask for `photo.jpg` at 400 pixels wide. Open this URL:

<http://localhost:4000/media/w=400/src/photo.jpg>

```text
GET /media/w=400/src/photo.jpg (in Chrome)
200 OK, content-type: image/avif, 400×267
```

Notice that:

- `/media` is where we mounted the Plug, and `src/photo.jpg` is
  `priv/photos/photo.jpg`.
- `w=400` sets only the width. The height follows the photo's proportions.
- The original is a JPEG, but Chrome got AVIF. Without a `format` option,
  ImagePipe picks AVIF or WebP when the browser accepts it.

If you mistype the file name, ImagePipe answers `404` with the body
`source not found`. If you leave out `src/`, as in `/media/w=400/photo.jpg`,
it answers `400` with the body `invalid transformation options`.

## Cropping to a square

With a width and a height, `fit=cover` fills the whole box and crops what
doesn't fit:

<http://localhost:4000/media/w=300/h=300/fit=cover/src/photo.jpg>

```text
GET /media/w=300/h=300/fit=cover/src/photo.jpg
200 OK, content-type: image/avif, 300×300
```

The photo covers the whole square, with the sides cropped off and the center
kept. Without `fit=cover`, the whole photo stays visible and the result is
300×200.

## Showing the image on a page

Image URLs are ordinary paths in the app, so templates use them with `~p`.
Replace the contents of
`lib/gallery_web/controllers/page_html/home.html.heex` with:

```heex
<Layouts.app flash={@flash}>
  <img src={~p"/media/w=400/h=300/fit=cover/src/photo.jpg"} alt="A photo" />
</Layouts.app>
```

Open <http://localhost:4000>. The page shows a 400×300 crop of the photo.
Notice that `~p` checks the path against the router: a typo in `/media`
gives a compile warning, while the options after it are checked by ImagePipe
when the image is requested.

## Next steps

We started an ImagePipe instance, mounted it in the router, and served
resized and cropped copies of a photo to a page. From here:

- [Requesting images](requesting-images.md): how URLs are built, option
  values, presets, and error responses.
- [Processing options](processing.md): every option, grouped by category.
- [Serving images from local files](serving-local-files.md),
  [an HTTP origin](serving-from-http.md), or [S3](serving-from-s3.md):
  where originals come from in production.
- `ImagePipe.Plug`: every option of the `forward`, and using it in a
  `Plug.Router`.
- [Serving and processing in one app](combined-usage.md): build URLs and process
  images in code with the same configuration.

Before deploying, set up [URL signing](signing-urls.md) so only your app can
create image URLs, and [caching](caching-processed-images.md) so each copy is
processed once.
