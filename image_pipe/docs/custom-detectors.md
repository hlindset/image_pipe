# Writing a custom detector

Replace the bundled face and object detector with your own model, a remote
service, or a test fake, so `detect` crops use its results. This guide
assumes ImagePipe is running in your app (see [Plug usage](plug-usage.md)).
`image_pipe_server` runs only the bundled detector.

## Implement the behaviour

A detector is a module that implements `ImagePipe.Transform.Detector`. This
one wraps a model behind `MyApp.Model.run/1`, which stands in for your own
code and returns boxes with a label and a score:

```elixir
# lib/my_app/detector.ex
defmodule MyApp.Detector do
  @behaviour ImagePipe.Transform.Detector

  @classes ["face", "car"]
  @model_version "my-model-v1"

  @impl true
  def supported_classes(_opts), do: @classes

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, @model_version}

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, :all)

    with {:ok, detections} <- MyApp.Model.run(image) do
      regions =
        for %{label: label, score: score, x: x, y: y, width: w, height: h} <- detections,
            classes == :all or label in classes do
          %{label: label, score: score, box: {x, y, w, h}}
        end

      {:ok, regions}
    end
  end
end
```

Three rules matter most, and the
[behaviour reference](`ImagePipe.Transform.Detector`) lists the rest:

- `supported_classes/1` returns every class name the detector can find,
  spelled as in URLs (`traffic_light`, not `traffic light`). A request for
  any other class fails with `400` before the image is fetched.
- `detect/2` returns only regions whose label is in `opts[:classes]`, or any
  label when it is `:all`. ImagePipe doesn't filter them, so a stray `car`
  moves a `detect=face` crop.
- `identity/1` names the model version. It is part of the cache key and the
  ETag, so changing it replaces crops made by the old model. Keep secrets
  out of it, since telemetry handlers can receive it.

Boxes are `{x, y, width, height}` in pixels from the top-left corner of the
image that `detect/2` receives.

## Report model files

If the detector loads model files from disk, add `ready?/1` and `warmup/1`.
`ready?/1` reports whether the model files are on disk. `warmup/1` loads
them at startup:

```elixir
@impl true
def ready?(_opts), do: File.exists?(MyApp.Model.path())

@impl true
def warmup(_opts), do: MyApp.Model.load()
```

While `ready?/1` returns `false`, a Plug configured with
`detector_required: true` answers `503` to `detect` requests. `warmup/1`
returns `:ok` or `{:error, reason}`.

If the detector can't run at all in some builds, return `false` from
`available?/1` and `{:error, {:detector, :unavailable}}` from `detect/2`,
and return a different identity while it is unavailable.
[Errors](`ImagePipe.Transform.Detector#module-errors`) in the behaviour
reference explains why.

## Configure the detector

Set the `detector` option to your module:

```elixir
# lib/my_app_web/router.ex
forward "/images", ImagePipe.Plug,
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ],
  detector: MyApp.Detector
```

The same option works in `ImagePipe.config/1` and in an `ImagePipe` instance.
To load models at startup, add the warmup worker to your supervision tree,
before the endpoint:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe.Transform.Detector.Warmup, detector: MyApp.Detector},
  MyAppWeb.Endpoint
]
```

## Check the results

Call the detector on a real image in `iex -S mix`:

```elixir
iex> image = Image.open!("priv/static/images/street.jpg")
iex> MyApp.Detector.detect(image, classes: ["car"])
{:ok, [%{label: "car", score: 0.91, box: {412, 230, 180, 96}}]}
```

Then request a crop through `ImagePipe.Plug` with the default Logger attached
(`ImagePipe.Telemetry.attach_default_logger/0`), for example
`/images/w=400/h=400/fit=cover/detect=car/src/street.jpg`. The log shows
whether the detector found regions:

```text
[info] image_pipe transform detect: detected
```

`no_regions` means the detector found nothing, and the crop used attention
cropping instead. A warning with `error` means `detect/2` returned an error
or a malformed result.

## Next steps

- [Content-aware cropping](content-aware-gravity.md) explains how regions
  and class weights become the crop's focus point.
- [Crop guides](processing/crop.md#crop-guides) lists the `detect` syntax.
- [Detection telemetry](telemetry-events.md#content-aware-crop-detection)
  describes the events a detector run emits.
