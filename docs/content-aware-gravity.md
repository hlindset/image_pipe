# Content-aware gravity (smart crop & face detection)

ImagePipe supports several content-aware ways to choose *where* a cover/crop is
anchored, on top of the usual fixed anchors and focal points:

| URL | What it does | Needs ML? |
| --- | --- | --- |
| `g:sm` | libvips **attention** smart crop — picks the most salient region | No |
| `g:obj:face` (and `c:W:H:obj:face`) | anchors the crop on **detected faces** | **Yes** |
| `g:obj` / `g:obj:all` | anchors on **all detected objects** (faces + COCO-80) | **Yes** |
| `g:obj:%c1:…:%cN` | anchors on specific object classes, e.g. `g:obj:car:dog` | **Yes** |
| `g:objw:%c1:%w1:…:%cN:%wN` | anchors on **named-class objects** with **per-class weights** (`all` broadens to every class) | **Yes** |
| `g:sm` + `smart_crop_face_detection` config | **blends** the attention point with detected faces | **Yes** |

`g:sm` works out of the box — it's pure libvips and needs no extra dependencies.
The face-aware and object-aware paths need an optional ML detector, which this
guide explains how to enable.

## Enabling face and object detection

Face and object detection are **off by default**. ImagePipe pulls no ML runtime
in a normal build; a host opts in by adding two dependencies:

```elixir
# mix.exs — in YOUR application's deps
{:image_vision, "~> 0.4"},
{:ortex, "~> 0.1"}
```

Both are required:

- **`image_vision`** provides `Image.FaceDetection` (YuNet) and
  `Image.Detection` (RT-DETR, COCO-80).
- **`ortex`** is the ONNX runtime `image_vision` runs models through.
  `image_vision` compiles the detection modules **only** when Ortex is present
  (`if ImageVision.ortex_configured?()`), so `image_vision` *without* `ortex`
  silently provides no detection. This is the single most common setup mistake.

Practical requirements:

- **A Rust toolchain** — `ortex` builds a native NIF (it needs `cargo`/`rustc`).
- **A one-time model download** — the YuNet face model (~340 KB) is fetched from
  HuggingFace on the **first** face detection request and cached on disk. The
  RT-DETR object model (~175 MB) must be pre-fetched explicitly (see
  [Warming up](#warming-up-avoiding-first-request-latency)); use
  `mix image_vision.download_models --detect` at build/deploy time to avoid
  first-request cold-start latency for object detection.
  The first cold face request therefore appears to "hang" while it downloads
  unless the warmup worker is used (see
  [Warming up](#warming-up-avoiding-first-request-latency)).

Once both deps compile, face and object detection **activates automatically** —
you don't have to configure anything. ImagePipe's default detector is a
`Composite` that routes `face` requests to the YuNet adapter
(`ImagePipe.Transform.Detector.ImageVision.Face`) and COCO-80 object requests to
the RT-DETR adapter (`ImagePipe.Transform.Detector.ImageVision.Objects`). Each
checks at runtime whether its `image_vision` module is loadable and uses it when
it is.

## What happens without it

ImagePipe never hard-fails just because the detector is missing. With no
`image_vision`/`ortex` (or when a request's image has no detectable face, or the
model errors), face-aware requests **fall back to `g:sm` libvips attention smart
crop** — a sensible result, just not face-aware. Your app keeps serving images.

If you would rather a face-*required* request fail loudly instead of silently
degrading, see [`detector_required`](#options) below.

## Options

Both options are passed to the plug at mount time (alongside `sources:`, etc.):

```elixir
plug ImagePipe.Plug,
  dialect: ImagePipe.Dialect.Imgproxy,
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
  - `false` — **graceful**: a face-aware request with no available detector falls
    back to attention.
  - `true` — **strict**: a face-aware (`g:obj:face`) request is **rejected
    before any source fetch or cache access** when the detector is unavailable,
    returning a 422. (Availability is a cheap in-process check, so this decision
    is made up-front.) Note that `smart_crop_face_detection` (face-assisted
    `g:sm`) is *never* hard-rejected — it's an enhancement to an
    always-valid attention crop, so it always degrades to plain attention.

## Warming up (avoiding first-request latency)

Because the model downloads (and loads) on first use, the first cold face
request pays that cost. To pre-load it at boot, add the optional, host-wired
warmup worker to **your** supervision tree:

```elixir
# in your application.ex children
{ImagePipe.Transform.Detector.Warmup, detector: :default}
```

The default `classes: :all` warms both the face (YuNet) and object (RT-DETR)
models. If you only use face detection, you can pass `classes: ["face"]` to skip
the larger RT-DETR model. It runs once, off the boot path (it does not block your
supervisor's startup), triggers the model load, and then terminates normally (it
is `restart: :transient`, so it is not restarted). If the detector is unavailable
it is a clean no-op. The `:detector` option mirrors the plug's — pass the same
value you gave the plug (`:default`, a custom module, or `nil` to disable).

There is also a build/deploy-time option: `mix image_vision.download_models
--detect` pre-fetches the RT-DETR object model (~175 MB). The YuNet face model
(~340 KB) is downloaded on first use regardless; use the warmup worker (or just
accept the first-request download) for face detection.

## Custom detectors

The detector is a small, product-neutral behaviour, so you can swap in your own
(a different model, a remote service, a fake for tests):

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

Then `detector: MyApp.MyDetector`. The `identity/1` return participates in the
cache key, so a model/version change you encode there correctly invalidates
cached results. Keep `identity/1` free of secrets — it appears in per-model
telemetry spans that fan out to all attached handlers. `supported_classes/1`
must be answerable even when the optional dep is absent; it is used for class
routing and availability checks before any model is loaded.

## General object gravity

Beyond face detection, ImagePipe supports the full `g:obj` object gravity
surface: specific COCO-80 classes, bare `obj` (all objects), and the `all`
pseudo-class.

**Class syntax.** Append one or more class names as colon-separated tokens:

```text
g:obj:car               # anchor on detected cars
g:obj:car:dog           # anchor on cars and dogs (class union)
g:obj                   # all detected objects — faces + all COCO-80 classes
g:obj:all               # explicit all-objects form, same as bare g:obj
c:W:H:obj:car           # crop form with specific class
```

Class names use the **underscore spelling** matching the COCO-80 vocabulary:
`traffic_light`, `sports_ball`, `hot_dog`, etc. The full 80-class list is in
`ImagePipe.Transform.Detector.ImageVision.Objects`.

**Union of detectors.** `g:obj` and `g:obj:all` route to *every* configured
child detector — both the face (YuNet) and object (RT-DETR) adapters run, and
their regions are merged before computing the crop focus. A class list routes
only to the detector(s) that own the requested classes; e.g. `g:obj:face` routes
only to YuNet, `g:obj:car` routes only to RT-DETR. Detection runs on the decoded
image inside the bounded transform pipeline (subject to `max_input_pixels`), and
successful responses are cached — but note that `g:obj`/`g:obj:all` runs *two*
models per cache miss, so size `max_input_pixels`/concurrency limits with the
heavier RT-DETR path in mind.

**Unknown classes degrade, never error.** If a requested class isn't claimed by
any configured detector, it is silently dropped. `g:obj:unicorn` produces the
same result as `g:obj` with no unicorn regions — the request succeeds and falls
back to attention saliency. Only classes that route to at least one child
contribute to the crop.

**Equal-weight centroid.** The crop focus is the `√area`-weighted centroid of
all detected regions, without per-class weights. With many mixed-size objects
the result naturally biases toward larger ones. If you want a face-centric crop
on a busy scene, use `g:obj:face` directly (filter: only faces), or use the
`objw:all:…` form (bias: detect everything, but weight faces higher — e.g.
`g:objw:all:1:face:3` — see [Per-class weights (`objw`)](#per-class-weights-objw)
below). Note `g:objw:face:3` (no `all`) still *filters* to faces, just like
`g:obj:face`; only the `all` pseudo-class keeps the other objects in play.

**Class-aware cache identity.** The cache key includes only the child detector
identities that the requested class set routes to. An object-only request
(`g:obj:car`) is unaffected by a face model version change, and vice versa.

**Model size and cold-start.** The RT-DETR model is approximately 175 MB. Unlike
the small YuNet face model, it is not downloaded on first use automatically — use
`mix image_vision.download_models --detect` at build/deploy time to pre-fetch
it, and add the warmup worker so it loads into memory before the first request
(see [Warming up](#warming-up-avoiding-first-request-latency)).

## How requests, the detector, and the cache interact

- `g:obj:face` and `g:obj:car:dog` (etc.) resolve the detected regions'
  **area-weighted centroid** to a focal point and reuse the normal focal-point
  crop. Multiple regions are combined by area; out-of-image or malformed boxes
  are dropped.
- The detector's **class-aware** `identity/1` is folded into the **cache key**
  for detection-aware requests. Only the child detectors that the requested class
  set routes to contribute to the key — so swapping the face model doesn't
  invalidate object-only cached results, and vice versa.
- When a detector runs, detection emits a `[:image_pipe, :transform, :detect]`
  telemetry span with honest duration (the model inference is real, eager work)
  — useful for spotting cold-start cost. Its `:result` metadata distinguishes a
  real detection (`:detected`), a normal no-object frame (`:no_regions`), and a
  configured detector that produced nothing usable (`:unavailable`, `:error`).
  The Composite also emits a nested `[:image_pipe, :transform, :detect, :model]`
  span per child detector that ran — see [telemetry.md](telemetry.md) for the
  full schema.
  When no detector is configured, nothing runs, so instead of a span ImagePipe
  emits a one-shot `[:image_pipe, :transform, :detect, :skipped]` marker
  (`result: :no_detector`). The opt-in default Logger escalates `:unavailable`,
  `:error`, and `:no_detector` to `:warning`. ImagePipe emits no request-time
  `Logger` calls itself — fallback observability is telemetry-only. See
  [telemetry.md](telemetry.md).

## Per-class weights (`objw`)

`objw` is a complementary form to `obj` that adds per-class weights to the
detection-filter model. Like `obj`, the named classes form the detection filter
(the spec); unlike `obj`, each class carries a numeric weight that biases the
weighted centroid toward higher-weighted classes.

### Syntax

```text
g:objw:%class1:%weight1:…:%classN:%weightN

# Examples
g:objw:face:3                 # filter to faces, weight 3 (one class → weight inert)
g:objw:person:2:face:3        # filter to person+face; faces weighted 3, persons 2
g:objw:all:2:face:3           # all-class detection; baseline weight 2, faces override to 3
g:objw:all:1:face:3           # all-class detection; faces weighted 3 (all:1 is the default)
c:W:H:objw:face:3             # crop form — same semantics
```

**Weights** are positive numbers (decimals are accepted; `≤ 0` is rejected at
parse). Bare `objw` with no pairs is a parse error.

**The `all` pseudo-class.** `all` is not a regular class name — it is the
pseudo-class that broadens the detection spec to `:all` (every detector runs,
every class counts). Without `all`, the spec is the listed class names. `all`
also sets the default weight for classes not explicitly named: `g:objw:all:2:face:3`
means "detect everything at weight 2, override faces to 3".

### `obj` and `objw` both filter; `all` broadens

Both `obj` and `objw` use their named classes as the detection filter (the spec).
The distinction is that `objw` adds weights:

- **`obj:face`** — filters to faces, uniform weight.
- **`objw:face:3`** — filters to faces, weight 3. (With one class, the weight
  is inert — all regions in the spec have the same weight, so the centroid is
  identical to `obj:face`.)
- **`objw:person:2:face:3`** — filters to person+face, persons weight 2, faces 3.
- **`objw:all:1:face:3`** — detects *everything* (`all` broadens spec), faces
  boosted 3× over the default weight 1.

**`objw:face:3` and `objw:all:1:face:3` are NOT equivalent.** The first gates
detection to faces only; the second detects every class with a face boost. Use
`g:objw:all:…` when you want all objects to contribute to the centroid with some
classes weighted more. Use `g:objw:face:3` (or `g:obj:face`) when you want only
faces to count.

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

**Why `√area`:** `area` alone (the equal-weight Slice 1 basis) makes class
weights nearly inert — a face is ~1/15 the *area* of a person bounding box, so
a 3× face boost (3 vs 15) still loses. `√area` tracks linear size, making the
face ~1/4 of the person instead. The result is a responsive, real lever: a
modest weight visibly moves the crop while keeping "bigger object wins" as the
natural fallback for equal-weight scenes.

Pure `weight` without area (each object gets one full vote) makes tiny
background objects hijack crops. `weight·√area` is the middle path: weights are
usable *and* size still matters.

### Worked example — nested scene

With a car (large, low-mid frame), a person (medium, mid frame), and a face
(small, high frame):

| Request | Resulting focal y | Behavior |
| --- | --- | --- |
| `obj:face` (filter) | 0.25 | car/person not considered — lands on face |
| `obj:all` (uniform) | 0.49 | car dominates; face barely registers |
| `objw:all:1:face:3` | 0.45 | gentle, real upward nudge toward the face |
| `objw:all:1:face:8` | 0.39 | firmer pull — each weight unit moves it |

### Honest default consequence

With uniform weights (`obj:all`), the **biggest box wins** — a portrait biases
toward the `person` box, not the face, under any formula. A face inside a huge
person box needs a larger boost than the same face in a tight portrait, because
the size gap is larger; `√area` compresses that gap into a responsive dial
rather than an on/off switch, but it does not erase it.

### Canonicalization

ImagePipe canonicalizes `objw` weights to a sparse map:
- Class weight entries equal to the effective default are dropped (trivial
  weight entries do not change the centroid and need not be stored).
- `objw:all:1` (default baseline) drops the `:default` key, leaving an empty
  map `%{}`.
- **`objw:face:3` and `objw:all:1:face:3` are NOT canonical equivalents** —
  they have different detection specs (`["face"]` vs `:all`) and produce
  different crops when other classes are present in the scene.
- Uniform weights (`objw:all:2`) produce the same *crop* as `obj:all` (the
  weight scalar cancels in the centroid) but a *different* cache key — a known,
  accepted redundancy.

## imgproxy compatibility & divergences

`g:obj:face` / `c:W:H:obj:face`, multi-class `g:obj:%c1:…:%cN` / `g:obj` /
`g:obj:all`, and `g:objw:%c1:%w1:…` / `c:W:H:objw:…` are all supported. The
remaining out-of-scope part of imgproxy's object gravity surface is
`objects_position`. ImagePipe uses `image_vision`'s YuNet face model (not
imgproxy's configurable YOLO models) and RT-DETR for COCO-80 objects (not YOLO),
so detected boxes — and the resulting crops — are compatible in intent but not
bit-identical to imgproxy. The face-assist blend weight is ImagePipe's own
approximation. Weight values accept positive decimals (imgproxy documents only
integer examples); this is an intentional superset. The full row-by-row mapping
and divergence notes are in
[imgproxy_support_matrix.md](imgproxy_support_matrix.md#smart-crop-object-detection-classification-and-best-format-models).
