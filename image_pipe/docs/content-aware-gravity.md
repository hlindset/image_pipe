# Content-aware cropping

Content-aware guides place a crop or cover resize around interesting regions:

| URL | What it does | Needs ML? |
| --- | --- | --- |
| `anchor=smart` | libvips **attention** smart crop — picks the most salient region | No |
| `detect=face` | anchors the crop on **detected faces** | **Yes** |
| `detect=all` | anchors on **all detected objects** (faces + COCO-80) | **Yes** |
| `detect=car,dog` | anchors on selected object classes | **Yes** |
| `detect=all,face:3` | detects every class and gives faces **three times the class weight** | **Yes** |
| `anchor=smart-face` | **blends** the attention point with detected faces | **Yes** |

`anchor=smart` uses libvips without extra dependencies. Face and object detection
need an optional ML detector.

Guides require a crop or a cover-family resize in the same group, for example
`/w=400/h=400/fit=cover/detect=face/src/portrait.jpg` or
`/crop=400,400/detect=all,face:3/src/scene.jpg`. A group may specify one of
`anchor`, `focus`, or `detect`. The guide applies to its source crop and cover
result crop; it resets at `-`.

## Enabling face and object detection

To enable face and object detection, add both dependencies to your application:

```elixir
# mix.exs
{:image_vision, "~> 0.4"},
{:ortex, "~> 0.1"}
```

`image_vision` provides YuNet face detection and RT-DETR object detection
(COCO-80). It compiles those modules only when the Ortex ONNX runtime is present.

Practical requirements:

- **A Rust toolchain** — `ortex` builds a native NIF (it needs `cargo`/`rustc`).
- **Model files** — YuNet (~340 KB) downloads from HuggingFace on first use and
  is cached on disk. Download RT-DETR (~175 MB) at build/deploy time with
  `mix image_vision.download_models --detect`. See
  [Warming up](#warming-up-avoiding-first-request-latency) to load models before
  serving requests.

## What happens without it

Missing detectors, empty detections, and detection errors fall back to libvips
attention cropping. A response that fell back after a detection error is sent
with `Cache-Control: no-store` and no ETag, so the next request runs detection
again. Set [`detector_required`](#options) to fail explicit detection requests
instead.

## Options

Configure the detector at mount time:

```elixir
plug ImagePipe.Plug,
  # ...
  detector: :default,        # default
  detector_required: false   # default
```

- **`detector`**: which detector backs the face- and object-aware paths.
  - `:default` *(default)*: the bundled `ImagePipe.Transform.Detector.Composite`,
    which routes faces to `ImageVision.Face` (YuNet) and objects to
    `ImageVision.Objects` (RT-DETR/COCO-80). Activates automatically when
    `image_vision` + `ortex` are loaded; reports unavailable (→ attention
    fallback) otherwise.
  - `nil`: detection disabled. Face-aware requests always fall back to attention.
  - a module implementing `ImagePipe.Transform.Detector`: a
    [custom detector](#custom-detectors).
- **`detector_required`**: boolean, default `false`.
  - `false`: unavailable detection falls back to attention.
  - `true`: an explicit `detect` request fails before the source is fetched
    when the detector isn't installed (`501`) or its model files aren't
    downloaded yet (`503`). A detection error while processing fails the
    request with `500`. `anchor=smart-face` still falls back to attention.

    A mount with `detector_required: true` answers `503` until the models are
    on disk. Run `mix image_vision.download_models --detect` for RT-DETR at
    deploy time, and the
    [warmup worker](#warming-up-avoiding-first-request-latency) for YuNet.

## Warming up (avoiding first-request latency)

To download the face model and load models at boot, add the warmup worker to
your supervision tree:

```elixir
# in your application.ex children
{ImagePipe.Transform.Detector.Warmup, detector: :default}
```

The default `classes: :all` warms both the face (YuNet) and object (RT-DETR)
models. If you only use face detection, you can pass `classes: ["face"]` to skip
the larger RT-DETR model. The worker runs once without blocking supervisor
startup, then exits normally. Its `:transient` restart policy leaves it stopped
after success. Unavailable detectors are skipped. Pass the same `:detector`
value as the Plug: `:default`, a custom module, or `nil` to disable.

Warmup still requires the RT-DETR model to be downloaded beforehand.

## Custom detectors

Implement `ImagePipe.Transform.Detector` to use another model, a remote service,
or a test fake:

```elixir
defmodule MyApp.MyDetector do
  @behaviour ImagePipe.Transform.Detector

  @impl true
  def supported_classes(_opts), do: ["face", "car"]

  @impl true
  def detect(image, opts) do
    classes = Keyword.get(opts, :classes, :all)
    # ... return product-neutral regions for the requested classes ...
    {:ok, [%{label: "face", score: 0.97, box: {x, y, width, height}}]}
    # box is {x, y, width, height} in absolute top-left pixels
  end

  @impl true
  def available?(_opts), do: true

  @impl true
  def identity(_opts), do: {__MODULE__, "my-model-v1"}

  # optional
  @impl true
  def warmup(_opts), do: :ok
end
```

Mount with `detector: MyApp.MyDetector`. Include the model version in `identity/1`
so model changes invalidate cached results and ETags. Keep it free of secrets:
it appears in per-model telemetry sent to all handlers. `supported_classes/1`
must be answerable even when the optional dep is absent; it is used for class
routing and availability checks before any model is loaded.

If your detector loads model files, implement the optional `ready?/1` callback.
A mount with `detector_required: true` answers `503` while it returns `false`.
Without it, the detector is ready whenever `available?/1` is true. When
`opts[:required]` is `true`, a detector that combines several models must
return an error if any of them fails.

## General object gravity

Detection supports specific COCO-80 classes, custom detector classes, and the
`all` pseudo-class.

**Class syntax.** List one or more comma-separated class names:

```text
detect=car                    # anchor on detected cars
detect=car,dog                # anchor on cars and dogs (class union)
detect=all                    # faces and all object classes
crop=400,400/detect=car        # guided source crop
```

Class names use the **underscore spelling** matching the COCO-80 vocabulary:
`traffic_light`, `sports_ball`, `hot_dog`, etc. The full 80-class list is in
`ImagePipe.Transform.Detector.ImageVision.Objects`.
Names start with a lowercase letter or digit and may contain lowercase
letters, digits, underscores, and hyphens. Duplicate class names are rejected.

**Routing.** `detect=all` runs every configured child detector and merges their
regions. A class list runs only the detectors for those classes: `face` uses
YuNet, `car` uses RT-DETR. Detection runs on decoded images subject to
`max_input_pixels`; successful responses can be cached. Account for RT-DETR's
cost when setting pixel and concurrency limits, especially with `detect=all`.

**Unknown classes.** A class that no configured detector supports, such as
`detect=unicorn`, fails with `400` before the source is fetched.

**Crop focus.** The focus is the `√area`-weighted centroid of detected regions;
malformed or out-of-image boxes are dropped. Larger regions contribute more.
Use `detect=face` for faces alone or `detect=all,face:3` to give faces more weight
among all objects. See [Per-class weights](#per-class-weights).

**Class-aware cache identity.** The cache key and ETag include only the child detector
identities that the requested class set routes to. An object-only request
(`detect=car`) is unaffected by a face model version change, and vice versa.
Requests with `anchor=smart-face` include the face detector identity. Across
`-` groups, identity includes the union of relevant detector classes.

## Detection telemetry

Detection spans measure inference, including cold-start costs. The default
Logger warns when a detector is missing, unavailable, or fails. See
[detection telemetry](telemetry-events.md#content-aware-crop-detection) for event names,
per-model spans, and outcomes.

## Per-class weights

Each `detect` class may carry a numeric weight that biases the centroid toward
that class. Unweighted entries use weight 1.

### Syntax

```text
detect=class1:weight1,class2:weight2

# Examples
detect=face:3                 # only faces (one class → weight cancels)
detect=person:2,face:3        # only people and faces, weighted 2 and 3
detect=all:2,face:3           # everything, baseline 2, face override 3
detect=all,face:3             # everything, baseline 1, face override 3
crop=400,400/detect=face:3    # guided source crop
```

**Weights** are positive decimals at most `1_000_000`. Exponent notation,
empty lists, duplicate classes, and malformed weights are rejected before
source access. Class order and equivalent integer/decimal spellings share
canonical identity.

`all` includes every class and sets the default weight for unnamed classes.
Without it, only the listed classes contribute. Thus `detect=face:3` has the
same focus as `detect=face`: all regions have the same weight, which cancels
in the centroid. Use `detect=all,face:3` to bias faces among other objects.

### Weighted centroid formula

The crop focus is computed as:

```
focal = Σ(pullᵢ · centerᵢ) / Σ(pullᵢ)
pullᵢ  = classWeight(labelᵢ) · √areaᵢ
```

`classWeight` is the explicit class weight, then the `all` baseline, then 1.
Square-root weighting gives larger regions more influence without letting
them dominate as strongly as raw area would. A face inside a large person box
may therefore need more weight than the same face in a tight portrait.
