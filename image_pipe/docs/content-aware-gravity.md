# Content-aware cropping

A crop or cover resize keeps only part of an image, and content-aware
cropping picks that part by looking at the picture rather than at a fixed
position. A 400×400 square from a wide group photo can keep the middle of
the frame, the most eye-catching area, or the faces. The URL options are
listed under
[Crop guides](processing/crop.md#crop-guides), and
[Enabling face and object detection](enabling-detection.md) sets up the
detector.

## Attention cropping

`anchor=smart` uses libvips' attention cropping. It scores the image for
edges, saturated color, and skin tones, and keeps the area that scores
highest. It needs no model, runs on every server, and works on any picture.
It doesn't know what a face or a car is, though, so a bright sign behind a
person can win over the person.

## Detection-guided cropping

`detect` runs a detector to find the regions that contain the classes you name,
such as `detect=face` or `detect=car,dog`, and centers the crop on them. The
bundled detector finds faces with the YuNet model and 80 everyday object
classes, from `person` and `car` to `cup` and `toothbrush`, with RT-DETR.
`detect=all` looks for every class the detector knows. A host can also plug in
[its own detector](custom-detectors.md), with its own classes.

The crop is centered on one focus point computed from all the regions, then
moved as little as needed to stay inside the image. A square crop of a
landscape photo with one person on the left keeps that person, and a crop of
two people standing apart keeps the space between them.

## Focus point from regions

Every region pulls the focus point toward its center. A bigger region pulls
harder, but not in proportion to its area: a box four times the area of
another pulls twice as hard. That keeps a large background object from
swamping a small subject, while still letting a close-up face win over a
distant one.

A region that extends past the image's edges, or has no area, is left out.
The detector's confidence score doesn't change the pull.

In formula form, the focus point is the weighted average of the region
centers, where each region's pull is its class weight times the square root
of its area:

```text
focus = Σ(pullᵢ · centerᵢ) / Σ(pullᵢ)
pullᵢ = classWeight(labelᵢ) · √areaᵢ
```

## Class weights

A class weight multiplies the pull of every region of that class, so in
`detect=all,face:3` a face pulls three times as hard as an object of the
same size. Weights only matter relative to other classes, since a weight
shared by every region cancels out of the average.
[detect](processing/crop.md#detect) lists the weight syntax.

A face inside a person's box shows why weights are useful. The person's
box is much larger, so `detect=person,face` stays near the middle of the
body, and `detect=person,face:3` moves toward the face.

## Blending attention with faces

`anchor=smart-face` starts from attention cropping and moves it toward
faces. It computes the attention point and the faces' focus point, then
takes a point 70% of the way from the first to the second. A photo with a
face gets a crop that favors the face but still includes what attention
cropping found interesting. A photo with no face gets plain attention
cropping.

Faces are only a hint here, so `anchor=smart-face` falls back to attention
cropping whenever detection fails, even on a server that requires
detection. A fallback after a detection error isn't cached, as with
`detect` below.

## Missing or failed detection

A `detect` crop can't always use regions:

- When the detector finds no regions, or only regions outside the image,
  the crop uses attention cropping. This is a normal result, cached like
  any other.
- When the server has no detector, the crop uses attention cropping, and
  the response is cached too. The cache entry is marked as made without a
  detector, so installing one later produces new crops instead of serving
  the old ones.
- When the detector fails on an image, the crop uses attention cropping,
  but the response isn't cached anywhere: it is sent with
  `Cache-Control: no-store` and no ETag. The next request tries detection
  again, so a passing failure doesn't stick.

These fallbacks treat detection as a hint: a picture is always served,
even if the crop misses the subject. A server can instead treat it as a
requirement (`detector_required`), and fail a `detect` request that can't
run detection. That suits sites where a wrong crop is worse than a missing
image, and it surfaces a deployment that lost its detector.
[Error responses](errors.md) lists the statuses.

A class the detector doesn't know, such as `detect=unicorn`, fails with
`400` before the image is fetched, whether or not detection is required. A
typo would otherwise look like a picture with nothing in it.

## Cost of detection

Detection is the most expensive crop guide.

- **Models run per class.** A request runs only the models its classes need:
  `detect=face` runs YuNet, `detect=car` runs RT-DETR, and `detect=all` or
  `detect=car,face` runs both. RT-DETR is far larger (about 175 MB against
  YuNet's 340 KB) and slower.
- **The whole image is in memory.** Like attention cropping, detection reads
  the entire decoded image, so ImagePipe holds it in memory instead of
  streaming it. Pixel limits and processing concurrency bound this.
- **The first request loads the model.** Each model loads once per server,
  and downloads first if it isn't on disk. Warmup at startup moves that wait
  out of the first request.
- **Results are cached.** A cached crop doesn't run detection again. The
  cache key and ETag include the versions of the models a request uses, so
  updating the face model replaces face crops but keeps cached car crops.

[Detection telemetry](telemetry-events.md#content-aware-crop-detection)
times each model run, including the first-load cost.
