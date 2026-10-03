# Processing images in Elixir

In this guide we'll add ImagePipe to a new Mix project, resize a photo from
`iex`, write the result to a file, and then crop and convert it.

You need Elixir 1.18 or newer and a JPEG photo.

## Adding the dependency

Create a project and change into it:

```bash
mix new thumbnails
cd thumbnails
```

Add ImagePipe to the dependencies in `mix.exs`:

```elixir
# mix.exs
defp deps do
  [
    {:image_pipe, "~> 0.1.0"}
  ]
end
```

Fetch it and compile:

```bash
mix deps.get
mix compile
```

The first compile downloads a prebuilt libvips, the image library ImagePipe
uses, so it needs a network connection.

Copy your photo into the project as `photo.jpg`:

```bash
cp /path/to/your/photo.jpg photo.jpg
```

The examples below use a 4000×2667 photo. With your photo, the widths match
and the heights follow its proportions.

## Building a configuration

Start `iex` with the project loaded:

```bash
iex -S mix
```

ImagePipe takes its settings from a configuration: where originals come
from, caches, default quality, and limits. The defaults are enough to process
a local file:

```elixir
iex> config = ImagePipe.config()
#ImagePipe.Config<instance: nil, ...>
```

## Describing the image with a plan

A plan lists the processing options for an image. We build plans with
`ImagePipe.URL`. Let's ask for a copy 400 pixels wide:

```elixir
iex> thumbnail = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400])
```

Notice that a plan is the same thing an image URL describes. Ask for its URL
to see the options:

```elixir
iex> ImagePipe.URL.url!(thumbnail, "photo.jpg")
"/w=400/src/photo.jpg"
```

`resize: [width: 400]` is `w=400` in a URL. The plan gives the same image
when served over HTTP.

## Running the plan

`ImagePipe.run/4` processes an image with a plan. `{:file, "photo.jpg"}` says
which image to read:

```elixir
iex> {:ok, result} = ImagePipe.run(config, thumbnail, {:file, "photo.jpg"})
```

`iex` prints the whole result, starting with
`{:ok, %ImagePipe.Result{terminal: :image, data: <<255, 216, ...`. Let's look
at its fields:

```elixir
iex> {result.format, result.width, result.height}
{:jpeg, 400, 267}
iex> result.content_type
"image/jpeg"
iex> byte_size(result.data)
13319
```

Notice that:

- The width is 400, and the height follows the photo's proportions.
- The result is a JPEG, like the original. Without a format in the plan,
  ImagePipe keeps the original's format.
- `result.data` holds the complete encoded image, ready to store or send.

If the file doesn't exist, `run` returns an error instead:

```elixir
iex> ImagePipe.run(config, thumbnail, {:file, "missing.jpg"})
{:error, {:source, :enoent}}
```

## Writing the result to a file

`ImagePipe.write/5` runs a plan like `run` and writes the image to a file:

```elixir
iex> {:ok, result} = ImagePipe.write(config, thumbnail, {:file, "photo.jpg"}, "thumbnail.jpg")
```

Open `thumbnail.jpg` in an image viewer. It's a 400×267 copy of the photo,
13,319 bytes. `write` returns the same result as `run`, and it replaces a file
that already exists. If the directory doesn't exist, as with
`"out/thumbnail.jpg"`, `write` returns `{:error, {:destination, :enoent}}`.

## Cropping to a square

With a width and a height, `fit: :cover` fills the whole box and crops what
doesn't fit:

```elixir
iex> square = ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 300, height: 300, fit: :cover])
iex> ImagePipe.URL.url!(square, "photo.jpg")
"/w=300/h=300/fit=cover/src/photo.jpg"
iex> {:ok, result} = ImagePipe.write(config, square, {:file, "photo.jpg"}, "square.jpg")
iex> {result.format, result.width, result.height}
{:jpeg, 300, 300}
iex> byte_size(result.data)
11581
```

Open `square.jpg`. The photo covers the whole square, with the sides cropped
off and the center kept.

An invalid option value raises an `ArgumentError` when you build the
plan, before any image is read. With `fit: :fill`:

```text
** (ArgumentError) expected :fit option to match at least one given type, but didn't match any. Here are the reasons why it didn't match each of the allowed types:

  * invalid value for :fit option: expected one of [:contain, :cover, :cover_down, :stretch, :auto], got: :fill
  * invalid value for :fit option: expected one of [:unset], got: :fill (in options [:resize])
```

The first reason lists the values `fit` accepts.

## Choosing the output format

The format belongs to the output, not to a processing step, so we set it with
`ImagePipe.URL.output/2`. Let's turn the square into WebP:

```elixir
iex> square_webp = ImagePipe.URL.output(square, format: :webp)
iex> ImagePipe.URL.url!(square_webp, "photo.jpg")
"/w=300/h=300/fit=cover/format=webp/src/photo.jpg"
iex> {:ok, result} = ImagePipe.write(config, square_webp, {:file, "photo.jpg"}, "square.webp")
iex> {result.format, result.width, result.height}
{:webp, 300, 300}
iex> byte_size(result.data)
6480
```

Notice that `square` is unchanged. Every `ImagePipe.URL` call returns a new
plan, so `square` still gives the 11,581-byte JPEG and `square_webp` gives a
6,480-byte WebP of the same pixels. The format comes from the plan or the
original, never from the file name.

## Next steps

We built a plan with `ImagePipe.URL`, ran it on a local file, and wrote
resized, cropped, and converted copies. From here:

- `ImagePipe.run/4` and `ImagePipe.write/5`: every input, including uploads
  held in memory and images from configured sources, and every error.
- `ImagePipe.Result`: the result fields, and the placeholder and image
  information results.
- `ImagePipe.URL`: building plans, and how builder options map to URL
  options.
- [Requesting images](requesting-images.md) and the
  [processing options](processing.md): what each option does to the image,
  with an Elixir example for each.
- [Combined Plug and Elixir usage](combined-usage.md): serve images over HTTP
  and process them in code with one configuration.

Before running this in production, read
[Caching processed images](caching-processed-images.md). A cache with a size
limit needs a supervised ImagePipe instance (see `ImagePipe.child_spec/1`).
