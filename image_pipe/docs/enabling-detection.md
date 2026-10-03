# Enabling face and object detection

Turn on the face and object detector, so `detect` and `anchor=smart-face`
crops follow the faces and objects in each image. This guide assumes
ImagePipe is running in your app (see [Getting started with Phoenix](phoenix-getting-started.md)) or as
`image_pipe_server`. `anchor=smart` works without any of this.

The bundled detector finds faces with YuNet and 80 kinds of objects with
RT-DETR. [Content-aware cropping](content-aware-gravity.md) explains how
the results place the crop.

## Install the detector

<!-- tabs-open -->

### Plug

Add `image_vision` and its ONNX runtime, `ortex`, next to `image_pipe`:

```elixir
# mix.exs
defp deps do
  [
    {:image_pipe, "~> 0.1.0"},
    {:image_vision, "~> 0.4"},
    {:ortex, "~> 0.1"}
  ]
end
```

> #### Detection needs a Rust toolchain {: .warning}
>
> `ortex` compiles a native library, so `cargo` and `rustc` must be
> installed wherever you run `mix deps.compile`, including your Docker build.

ImagePipe uses the detector as soon as both dependencies are compiled in.
The `detector` option already defaults to it.

### image_pipe_server

Use the `-vision` variant of the image:

```bash
docker run --read-only --tmpfs /tmp -p 8080:8080 -v ./config.toml:/etc/image_pipe/config.toml:ro -v ./images:/data/images:ro ghcr.io/hlindset/image_pipe_server:0.1.0-vision
```

<!-- tabs-close -->

## Load the models

<!-- tabs-open -->

### Plug

Each model downloads the first time it is used. RT-DETR, the object model,
is about 175 MB, so download it when you build or deploy instead:

```bash
mix image_vision.download_models --detect
```

Models are stored in `image_vision`'s cache directory, by default under the
user's cache directory (`~/.cache/image_vision` on Linux). If you build a
release on one machine or user and run it on another, set the same
directory for both:

```elixir
# config/config.exs
config :image_vision, :cache_dir, "/var/lib/image_vision/models"
```

Then add the warmup worker to your supervision tree. It downloads the face
model, YuNet (about 340 KB), and loads both models, so the first detection
request doesn't wait for them:

```elixir
# lib/my_app/application.ex
children = [
  {ImagePipe.Transform.Detector.Warmup, detector: :default},
  MyAppWeb.Endpoint
]
```

The worker runs once in the background and doesn't delay startup. Pass
`classes: ["face"]` as well if you only use face detection, to skip
RT-DETR.

> #### Required detection needs the models on disk {: .warning}
>
> With `detector_required: true`, requests don't download models. A
> `detect` request answers `503` until every model it needs is on disk, so
> run the warmup worker or download the models ahead of time.

### image_pipe_server

The `-vision` image has both models built in and loads them when the
server starts. It needs no network access for detection.

<!-- tabs-close -->

## Require detection

By default, a `detect` request that can't run detection still succeeds,
cropped with attention cropping instead. To fail those requests instead,
set `detector_required`:

<!-- tabs-open -->

### Plug

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
  detector_required: true
```

### image_pipe_server

```toml
[processing]
detector_required = true
```

<!-- tabs-close -->

[Error responses](errors.md) lists the statuses those requests get.
`anchor=smart-face` always falls back to attention cropping.
[Missing or failed detection](content-aware-gravity.md#missing-or-failed-detection)
explains when to require detection.

A configuration that requires detection without a working detector fails
before it serves anything, with the message `detector_required: the
detector is not available in this build`:

<!-- tabs-open -->

### Plug

`ImagePipe.config/1`, the `ImagePipe` child specification, and an
`ImagePipe.Plug` mount configured in the router raise `ArgumentError`.

### image_pipe_server

The image without the `-vision` variant refuses to start and logs the
message.

<!-- tabs-close -->

## Check that detection runs

Turn on the default request log:

<!-- tabs-open -->

### Plug

```elixir
# lib/my_app/application.ex, in start/2
ImagePipe.Telemetry.attach_default_logger()
```

### image_pipe_server

```toml
[telemetry]
log_level = "info"
```

<!-- tabs-close -->

Then request a face crop of a portrait. For a Plug, add the path you
forwarded to `ImagePipe.Plug`, such as `/images`:

```bash
curl -o face.jpg "http://localhost:8080/w=400/h=400/fit=cover/detect=face/src/woman.jpg"
```

The log shows the face model running and finding the face:

```text
[info] image_pipe transform detect model: ok (1 regions, ImagePipe.Transform.Detector.ImageVision.Face)
[info] image_pipe transform detect: detected
```

Other results on the `detect` line:

- `no_regions`: the model ran and found nothing, so the crop used attention
  cropping.
- `unavailable`, logged as a warning: the detector dependencies aren't
  installed.
- `error`, logged as a warning: the model failed on this image.
- `skipped (no detector configured)`, logged as a warning: the `detector`
  option is `nil`.

## Next steps

- [Crop guides](processing/crop.md#crop-guides) lists the `detect` and
  `anchor` syntax and the class names.
- [Detection telemetry](telemetry-events.md#transform-detect)
  describes the detection events, including per-model timings.
- [Writing a custom detector](custom-detectors.md) replaces the bundled
  detector with your own model or service.
