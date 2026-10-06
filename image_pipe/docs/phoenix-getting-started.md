# Getting started with Phoenix

In this guide we'll add ImagePipe to a new Phoenix app, serve resized copies
of an image from it, and show one on a page, with its URL built in the template.

You need Elixir 1.18 or newer, the Phoenix installer (`mix archive.install
hex phx_new`), and a JPEG image.

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

> #### ImagePipe needs `req` 0.8.0-rc.0 {: .warning}
>
> ImagePipe depends on `req` `~> 0.8.0-rc.0`, and a new Phoenix app locks an
> older version. Unlock it before fetching, or `mix deps.get` stops with a
> version conflict over `req`:
>
> ```bash
> mix deps.unlock req
> mix deps.get
> ```

## Adding a folder of images

ImagePipe reads originals from a folder and makes processed copies of them on
request. Create `priv/originals` and copy your image into it as `cat.jpg`:

```bash
mkdir -p priv/originals
cp /path/to/your/image.jpg priv/originals/cat.jpg
```

The examples below use a 4000×2667 image. With your image, the widths match
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
     originals: [
       adapter: ImagePipe.Source.File,
       match: :path,
       options: [root: Application.app_dir(:gallery, "priv/originals"), root_id: "originals"]
     ]
   ]},
  # Start to serve requests, typically the last entry
  GalleryWeb.Endpoint
]
```

This starts an ImagePipe instance named `Gallery.Images` with one source
named `originals`. A source is a place ImagePipe reads originals from:

- `adapter: ImagePipe.Source.File` reads files from a directory.
- `match: :path` sends every image path in a URL to this source.
- `root` is that directory, `priv/originals` in our app.
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

```text
[info] Running GalleryWeb.Endpoint with Bandit 1.x.x at 127.0.0.1:4000 (http)
```

An image URL lists processing options, then `src/`, then the image's path in
the source. Let's ask for `cat.jpg` at 400 pixels wide. Open this URL:

<http://localhost:4000/media/w=400/src/cat.jpg>

```text
GET /media/w=400/src/cat.jpg (in Chrome)
200 OK, content-type: image/avif, 400×267
```

Notice that:

- `/media` is where we mounted the Plug, and `src/cat.jpg` is
  `priv/originals/cat.jpg`.
- The original is a JPEG, but Chrome got AVIF. Without a `format` option,
  ImagePipe picks AVIF or WebP when the browser accepts it.

If you mistype the file name, ImagePipe answers `404` with the body
`source not found`. If you leave out `src/`, as in `/media/w=400/cat.jpg`,
it answers `400`, and the body points at the problem:

```text
invalid transformation options

/w=400/cat.jpg
              ^
              |
              missing src/, src64/, or enc/ before the image path
```

## Showing the image on a page

Image URLs are ordinary paths in the app, so templates use them with `~p`.
Replace the contents of
`lib/gallery_web/controllers/page_html/home.html.heex` with:

```heex
<Layouts.app flash={@flash}>
  <img src={~p"/media/w=400/h=300/fit=cover/src/cat.jpg"} alt="A cat" />
</Layouts.app>
```

Open <http://localhost:4000>. The page shows a 400×300 copy of the image,
cropped to fill the box by `fit=cover`.

## Building URLs in templates

ImagePipe can build URLs from the instance's settings. First, set
`base_url` to the path of the `forward`:

```elixir
# lib/gallery/application.ex
{ImagePipe,
 name: Gallery.Images,
 base_url: "/media",
 sources: [
   # ...
 ]},
```

Then make ImagePipe's `image_url` helper available in every template. In
`lib/gallery_web.ex`, add a line to `html_helpers`:

```elixir
# lib/gallery_web.ex
defp html_helpers do
  quote do
    # ... the generated imports and aliases
    use ImagePipe.URL.Helpers, instance: Gallery.Images
  end
end
```

Stop the server (Ctrl+C twice) and start it again with
`mix phx.server`, so the instance picks up `base_url`. Then replace
the hand-written path in the template:

```heex
<Layouts.app flash={@flash}>
  <img
    src={image_url("cat.jpg", group: [resize: [width: 400, height: 300, fit: :cover]])}
    alt="A cat"
  />
</Layouts.app>
```

Reload <http://localhost:4000>. The page looks the same, and the image's
address is `/media/w=400/h=300/fit=cover/src/cat.jpg`, the path we wrote by
hand before. Each `group:` holds the options of one processing step, and
`resize:` writes `w=`, `h=`, and `fit=`.

Now change `fit: :cover` to `fit: :bogus` and save. When Phoenix
recompiles the template, the terminal shows a warning that points at its
line:

```text
warning: image_url: invalid_value at {:group, 0, :fit}: invalid value for :fit option: expected one of [:contain, :cover, :stretch, :auto], got: :bogus
└─ lib/gallery_web/controllers/page_html/home.html.heex:3: GalleryWeb.PageHTML.home/1
```

Notice that the mistake shows up when the template compiles. The page still
renders: the server rejects the image's URL with `400`, so the browser shows
a broken image in place of the cat, and each render logs:

```text
[warning] image_url (lib/gallery_web/controllers/page_html/home.html.heex:3): invalid_value at {:group, 0, :fit}
```

Change it back to `fit: :cover`.

## Next steps

We started an ImagePipe instance, mounted it in the router, and served
resized copies of an image to a page, with URLs written by hand and built in
the template. From here:

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
- `ImagePipe.URL.Helpers`: what `image_url` checks, and failing the build or
  tests on a mistake.

Before deploying, set up [URL signing](signing-urls.md) so only your app can
create image URLs, and [caching](caching-processed-images.md) so each copy is
processed once.
