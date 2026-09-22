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

Both are required:

- **`image_vision`** provides `Image.FaceDetection` (YuNet) and
  `Image.Detection` (RT-DETR, COCO-80).
- **`ortex`** is the ONNX runtime `image_vision` runs models through.
  `image_vision` compiles its detection modules only when Ortex is present.

Practical requirements:

- **A Rust toolchain** — `ortex` builds a native NIF (it needs `cargo`/`rustc`).
- **Model files** — YuNet (~340 KB) downloads from HuggingFace on first use and
  is cached on disk. Download RT-DETR (~175 MB) at build/deploy time with
  `mix image_vision.download_models --detect`. See
  [Warming up](#warming-up-avoiding-first-request-latency) to load models before
  serving requests.

Once both dependencies compile, the default `Composite` detector routes `face`
requests to the YuNet adapter
(`ImagePipe.Transform.Detector.ImageVision.Face`) and COCO-80 object requests to
the RT-DETR adapter (`ImagePipe.Transform.Detector.ImageVision.Objects`). Each
checks whether its `image_vision` module is available at runtime.

## What happens without it

Missing detectors, empty detections, and detection errors fall back to libvips
attention cropping. Set [`detector_required`](#options) to reject explicit
detection requests when the detector is unavailable.

## Options

Configure the detector at mount time:

```elixir
plug ImagePipe.Plug,
  # ...
  detector: :default,        # default
  detector_required: false   # default
```

- **`detector`** — which detector backs the face- and object-aware paths.
  - `:default` *(default)* — the bundled `ImagePipe.Transform.Detector.Composite`,
    which routes faces to `ImageVision.Face` (YuNet) and objects to
    `ImageVision.Objects` (RT-DETR/COCO-80). Activates automatically when
    `image_vision` + `ortex` are loaded; reports unavailable (→ attention
    fallback) otherwise.
  - `nil` — detection disabled. Face-aware requests always fall back to attention.
  - a module implementing `ImagePipe.Transform.Detector` — a
    [custom detector](#custom-detectors).
- **`detector_required`** — boolean, default `false`.
  - `false` — unavailable detection falls back to attention.
  - `true` — an explicit `detect` request returns 422 before source resolution,
    fetch, or cache access when a required detector is unavailable.
    `anchor=smart-face` still falls back to attention.

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

**Unknown classes.** The bundled composite drops classes no child claims.
`detect=unicorn` falls back to attention cropping.

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

Detection emits a `[:image_pipe, :transform, :detect]` span. Inference is eager,
so its duration includes model work and cold-start costs. The `:result` is
`:detected`, `:no_regions`, `:unavailable`, or `:error`. The composite emits a
nested `[:image_pipe, :transform, :detect, :model]` span for each child it runs.

With no configured detector, ImagePipe emits a one-shot
`[:image_pipe, :transform, :detect, :skipped]` event with `result: :no_detector`.
The opt-in default Logger logs `:unavailable`, `:error`, and `:no_detector` at
`:warning`. Request-time detection diagnostics use telemetry; ImagePipe does
not call Logger directly. See [Telemetry](telemetry.md) for the full schema.

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

`classWeight` resolves a region's label against the weight map:

```
classWeight(label) = weights[label] ?? weights[:default] ?? 1
```

`√area` balances object size and class weight. Using area directly would let
large boxes dominate; ignoring area would give tiny background objects as much
influence as large subjects. For a face with 1/15 of a person's bounding-box
area, square-root weighting reduces the size difference to about 1/4.

### Worked example — nested scene

With a car (large, low-mid frame), a person (medium, mid frame), and a face
(small, high frame):

| Request | Resulting focal y | Behavior |
| --- | --- | --- |
| `detect=face` (filter) | 0.25 | car/person not considered — lands on face |
| `detect=all` (uniform) | 0.49 | car dominates; face barely registers |
| `detect=all,face:3` | 0.45 | moves focus upward toward the face |
| `detect=all,face:8` | 0.39 | stronger face bias |

A face inside a large person box needs more weight than the same face in a
tight portrait: square-root weighting reduces the size difference but does
not remove it.

### Canonicalization

ImagePipe canonicalizes weights to a sparse map:

- Class weights equal to the effective default are dropped.
- `detect=all:1` (default baseline) drops the `:default` key, leaving an empty
  map `%{}`.
- `detect=face:3` and `detect=all,face:3` have distinct canonical identities:
  they have different detection specs (`["face"]` vs `:all`) and produce
  different crops when other classes are present in the scene.
- Uniform weights (`detect=all:2`) produce the same crop as `detect=all` (the
  weight scalar cancels in the centroid) but a *different* cache key — a known,
  accepted redundancy.

## Imgproxy comparison

ImagePipe uses YuNet for faces and RT-DETR for COCO-80 objects; imgproxy uses
configurable YOLO models. These model differences and ImagePipe's face-assist
blend can produce different crops. ImagePipe accepts positive decimal weights.
