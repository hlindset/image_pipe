# Watermarks

A watermark composites an image asset over the group's result. It is the last
stage of a group, after effects, canvas, padding, and background, so it
addresses the whole displayed frame, including padding.

| URL | Elixir | Values / behavior |
| --- | --- | --- |
| `wm=logo` | `watermark: :logo` | Host-configured asset name |
| `wm-src64=<base64url>` | `watermark_source: "brand/logo.png"` | Request-supplied source, when the host enables it |
| `wm-enc=<token>` | Generated from `watermark_source` | Concealed request source |
| `wm-opacity=0.5` | `watermark_opacity: 0.5` | 0 to 1, default 1; multiplies the asset's base opacity |
| `wm-scale=0.25` | `watermark_scale: 0.25` | Fit inside this fraction of the frame, greater than 0 and at most 1 |
| `wm-at=bottom-right` | `watermark_at: :bottom_right` | Named anchor, center by default |
| `wm-offset=10,-5pct` | `watermark_offset: {10, {:pct, -5}}` | Signed pixels or percentages of the frame |
| `wm-tile` | `watermark_tile: true` | Repeat the asset across the frame |
| `wm-gap=20,5pct` | `watermark_gap: {20, {:pct, 5}}` | Non-negative spacing between tiles; requires `wm-tile` |

Exactly one of `wm`, `wm-src64`, and `wm-enc` names the asset, and the other
options require one of them. Watermark options reset at `-`.

```text
/w=800/wm=logo/wm-at=bottom-right/wm-offset=16,16/wm-scale=0.2/src/photos/beach.jpg
```

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(
  resize: [width: 800],
  watermark: :logo,
  watermark_at: :bottom_right,
  watermark_offset: {16, 16},
  watermark_scale: 0.2
)
```

## Size and placement

With `wm-scale`, the asset is fitted, with enlargement, inside that fraction of
the frame width and height, keeping its aspect ratio. An upscaled raster asset
softens. Without `wm-scale`, the asset is drawn at its natural size times the
group's effective DPR.

Anchors place the asset inside the frame. Positive offsets move it inward from
right and bottom anchors and forward from left, top, and center. Pixel offsets
scale with effective DPR; percentages resolve against the frame. Placement is
not clamped: an offset can push the asset partly outside the frame, where it is
clipped, and an asset entirely outside the frame draws nothing.

With `wm-tile`, one tile sits where the single asset would, and the grid
repeats in every direction from it. `wm-gap` adds space to the right of and
below each tile.

## Assets

Host assets are configured by name with `watermarks`; see
[configuration](../configuration.md#watermarks). Request-supplied sources
(`wm-src64`, `wm-enc`) require `request_watermarks: true`. Both resolve through
the configured source mounts and input cache like the main source, so mount
rules, body limits, and `max_input_pixels` apply to them. Assets use their
default frame and EXIF orientation. Their metadata is dropped; output metadata
and color policy describe the main source.

An asset is color-managed into the frame's space and composited over it: an
untagged asset is sRGB, and both land in the frame's ICC profile, or in sRGB
when the frame has none. A color asset turns a gray frame into RGB.
Transparent parts of the asset leave the frame unchanged. A frame without alpha
keeps none; a transparent frame gains coverage where the asset is opaque.

When generating URLs, a builder with `encrypt_source: true` conceals watermark
sources as `wm-enc`, the same way it conceals the main source.

## Failures and caching

Unknown names, disabled request sources, and inert options fail with `400`
before any source access. An asset that cannot be fetched fails the request
with the status a main-source failure would produce, and an undecodable asset
fails with `415`; a request never silently drops its watermark.

The asset's source identity, its byte identity, and the effective opacity enter
the cache key and ETag; host entry names do not. A conditional request is
answered with `304` before either source is fetched.
