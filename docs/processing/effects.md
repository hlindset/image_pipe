# Effects

[All processing options](../processing.md)

Effects work with or without resizing. Pass the Elixir options below to
`ImagePipe.group/2`. All effects start disabled in each group.

## Option reference

| URL example | Elixir example | Values / defaults |
| --- | --- | --- |
| `blur=2` | `blur: 2` | Nonnegative sigma; 0 disables |
| `progressive-blur=4,down,0.2,0.8` | `progressive_blur: [sigma: 4, angle: 0, start: 0.2, stop: 0.8]` | Nonnegative maximum sigma; default direction down, start 0, stop 1; 0 sigma disables |
| `sharpen=1.5` | `sharpen: 1.5` | Nonnegative sigma; 0 disables |
| `pixelate=8` | `pixelate: 8` | Integer block size ≥ 1; 1 disables |
| `gray` | `gray: true` | Grayscale; boolean |
| `bitonal` | `bitonal: true` | Black and white; boolean |
| `monochrome=0.8,704214` | `monochrome: [intensity: 0.8, color: "704214"]` | Intensity `0..1`; optional color defaults to `b3b3b3` |
| `duotone=1,123456,efab89` | `duotone: [intensity: 1, shadow: "123456", highlight: "efab89"]` | Intensity `0..1`; default colors black and white |
| `brightness=30` | `brightness: 30` | Integer addition from -255 to 255; 0 is identity |
| `contrast=1.5` | `contrast: 1.5` | Positive factor; 1 is identity |
| `saturation=0.7` | `saturation: 0.7` | Positive factor; 1 is identity |
| `colorize=0.3,red,keep-alpha` | `colorize: [opacity: 0.3, color: "red", keep_alpha: true]` | Opacity `0..1`, required color; keep-alpha defaults false |
| `gradient=0.8,black,down,0.2,0.9` | `gradient: [opacity: 0.8, color: "black", angle: 0, start: 0.2, stop: 0.9]` | Opacity/start/stop `0..1`; required color; default angle 0, start 0, stop 1 |

URL colors are bare three/six-digit hex or CSS names. Elixir also accepts
RGB tuples and hex strings with `#`. Comma-separated URL values cannot contain
empty placeholders. Supply either both duotone colors or neither.

Blur/sharpen sigma and pixelate block size use physical pixels, unaffected by
DPR. Monochrome/duotone intensity and colorize/gradient opacity of 0 disable
the operation. Explicit identity values are still validated.

## Order effects deliberately

Effects always run in this order within a group:

`blur → progressive-blur → sharpen → pixelate → gray → bitonal → monochrome → duotone → brightness → contrast → saturation → colorize → gradient`

Use groups to change the order. These examples apply brightness after contrast:

```text
/contrast=2/-/brightness=30/src/photos/beach.jpg
```

```elixir
ImagePipe.new()
|> ImagePipe.group(contrast: 2)
|> ImagePipe.group(brightness: 30)
```

## Alpha and gradients

Colorize produces an opaque result unless `keep-alpha` is set. Gradient
preserves source alpha. Zero opacity skips either effect without changing alpha.

Gradient directions follow the current display axes: `down` is 0°, `left` 90°,
`up` 180°, and `right` 270°. URLs also accept signed decimal angles; angles wrap
modulo 360. Reversing start/stop reverses the ramp; equal values create a hard step.

See the [pixel-effect contract](../api_contract.md#pixel-effects) for identity
and representation details.

## Progressive blur

`progressive-blur=sigma[,direction[,start[,stop]]]` transitions from unblurred
at `start` to the maximum Gaussian sigma at `stop`. Direction and stops follow
the gradient conventions above, including reversed ramps and hard steps.
Stops range from 0 to 1. The effect addresses the display frame after resizing;
sigma uses physical pixels, unaffected by DPR.

The varying radius is approximated by interpolating eight Gaussian sigma
intervals. Filtering and blending use premultiplied alpha to avoid colored
fringes at transparent edges. Multiple blur kernels require a materialized
input and cost more than a single uniform blur.
