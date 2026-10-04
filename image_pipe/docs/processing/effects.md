# Effects

Effects filter the image, adjust its colors, or lay a color over it, with or
without resizing.

Every effect is off unless the [group](../requesting-images.md#processing-groups)
sets it, and each group starts with all effects off again. Effects that take a
color accept a hex value or a CSS name, as described under
[colors](../requesting-images.md#colors). On a grayscale image, `monochrome`,
`duotone`, `colorize`, and `gradient` produce a color image only if one of
their colors isn't a neutral gray. The default `monochrome` and `duotone`
colors keep it gray.

## Effect order

Effects run after resizing and cropping, in this order, whatever order the URL
lists them in:

`blur`, `progressive-blur`, `sharpen`, `pixelate`, `gray`, `bitonal`,
`monochrome`, `duotone`, `brightness`, `contrast`, `saturation`, `colorize`,
`gradient`

To run them in another order, put them in separate groups. This URL adjusts
brightness after contrast:

<!-- tabs-open -->

### URL

```text
/contrast=2/-/brightness=30/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.new()
|> ImagePipe.URL.group(contrast: 2)
|> ImagePipe.URL.group(brightness: 30)
```

<!-- tabs-close -->

Where effects sit among the other stages is described under
[processing order](../processing.md#processing-order).

## Filters

### blur

Accepts a non-negative [number](../requesting-images.md#numbers), the Gaussian
blur sigma. Default: none. `blur=0` has no effect.

Blurs the whole image. Larger values blur more. The sigma is in output pixels,
so [`dpr`](resize.md#dpr) doesn't change it.

<!-- tabs-open -->

### URL

```text
/w=800/blur=2/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 800], blur: 2)
```

<!-- tabs-close -->

### progressive-blur

Accepts `sigma,direction,start,stop`. Only the sigma is required:

- `sigma` is the maximum blur, a non-negative number. `0` has no effect.
- `direction` is `down` (default), `left`, `up`, or `right`, or an angle in
  degrees, as described under [gradient](#gradient).
- `start` and `stop` are [fractions](../requesting-images.md#fractions) of the
  distance across the image, in that direction. They default to `0` and `1`.

Default: none. The image is sharp before `start`, and the blur grows to the full
sigma at `stop`. Swapping `start` and `stop` reverses the ramp, and equal values
switch from sharp to fully blurred in one step. The sigma is in output pixels,
so `dpr` doesn't change it. A progressive blur is slower than `blur`.

The values are positional, so you can't skip one: to set `start`, also write a
direction, as in `progressive-blur=4,down,0.5`. An empty value, such as
`progressive-blur=4,,0.5`, fails with `400`.

<!-- tabs-open -->

### URL

```text
/progressive-blur=4,down,0.2,0.8/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, progressive_blur: [sigma: 4, direction: :down, start: 0.2, stop: 0.8])
```

<!-- tabs-close -->

### sharpen

Accepts a non-negative number, the sharpening sigma. Default: none. `sharpen=0`
has no effect.

Sharpens edges. The sigma is in output pixels, so `dpr` doesn't change it.

<!-- tabs-open -->

### URL

```text
/w=400/sharpen=1.5/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, resize: [width: 400], sharpen: 1.5)
```

<!-- tabs-close -->

### pixelate

Accepts a whole number of 1 or more, the block size in pixels. Default: none.
`pixelate=1` has no effect.

Replaces the image with square blocks of one color each. The block size is in
output pixels, so `dpr` doesn't change it. `pixelate=0` fails with `400`.

<!-- tabs-open -->

### URL

```text
/pixelate=8/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, pixelate: 8)
```

<!-- tabs-close -->

## Color adjustments

### gray

A [boolean](../requesting-images.md#booleans). Default: `false`.

Converts the image to grayscale. Transparency is kept.

<!-- tabs-open -->

### URL

```text
/gray/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, gray: true)
```

<!-- tabs-close -->

### bitonal

A [boolean](../requesting-images.md#booleans). Default: `false`.

Converts the image to pure black and white: pixels darker than middle gray (128
on a 0 to 255 scale) become black, and the rest become white. Transparency is
kept, including partial transparency.

<!-- tabs-open -->

### URL

```text
/bitonal/src/scans/receipt.png
```

### Elixir

```elixir
ImagePipe.URL.group(builder, bitonal: true)
```

<!-- tabs-close -->

### monochrome

Accepts `intensity,color`:

- `intensity` is a fraction. `0` has no effect, and `1` applies the full
  effect.
- `color` is optional and defaults to `b3b3b3`, a light gray.

Default: none. Recolors the image in shades of one color, from black in the
shadows to `color` in the highlights.

<!-- tabs-open -->

### URL

```text
/monochrome=0.8,704214/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, monochrome: [intensity: 0.8, color: "704214"])
```

<!-- tabs-close -->

### duotone

Accepts `intensity`, `intensity,shadow`, or `intensity,shadow,highlight`:

- `intensity` is a fraction. `0` has no effect, and `1` applies the full
  effect.
- `shadow` and `highlight` are colors. They default to black and white.

Default: none. Recolors the image with two colors: dark areas take the shadow
color and light areas the highlight color.

<!-- tabs-open -->

### URL

```text
/duotone=1,123456,efab89/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, duotone: [intensity: 1, shadow: "123456", highlight: "efab89"])
```

<!-- tabs-close -->

### brightness

Accepts a whole number from `-255` to `255`. Default: none. `brightness=0` has
no effect.

Adds the value to every color channel on a 0 to 255 scale. A 16-bit image
shifts by the same fraction of its range, so `brightness=40` lightens it as
much as an 8-bit image. Positive values lighten
the image and negative values darken it.

<!-- tabs-open -->

### URL

```text
/brightness=-20/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, brightness: -20)
```

<!-- tabs-close -->

### contrast

Accepts a number greater than 0, a contrast factor with no upper limit.
Default: none. `contrast=1` has no effect.

Values above 1 increase contrast, and values below 1 reduce it. `contrast=0`
fails with `400`.

<!-- tabs-open -->

### URL

```text
/contrast=1.25/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, contrast: 1.25)
```

<!-- tabs-close -->

### saturation

Accepts a number greater than 0, a saturation factor with no upper limit.
Default: none. `saturation=1` has no effect.

Values above 1 make colors more vivid, and values below 1 make them duller.
Use [`gray`](#gray) for full grayscale, since `saturation=0` fails with `400`.

<!-- tabs-open -->

### URL

```text
/saturation=0.7/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder, saturation: 0.7)
```

<!-- tabs-close -->

## Color overlays

### colorize

Accepts `opacity,color` or `opacity,color,keep-alpha`:

- `opacity` is a fraction. `0` has no effect.
- `color` is required.
- `keep-alpha` is optional and keeps the image's transparency.

Default: none. Blends the color evenly over the whole image at the given
opacity. The result is opaque unless you add `keep-alpha`.

<!-- tabs-open -->

### URL

```text
/colorize=0.3,red,keep-alpha/src/logos/brand.png
```

### Elixir

```elixir
ImagePipe.URL.group(builder, colorize: [opacity: 0.3, color: "red", keep_alpha: true])
```

<!-- tabs-close -->

### gradient

Accepts `opacity,color,direction,start,stop`:

- `opacity` is a fraction, the strength of the color at the end of the ramp.
  `0` has no effect.
- `color` is required.
- `direction` is the way the color grows: `down` (default), `left`, `up`, or
  `right`. It can also be an angle in degrees, clockwise from `down`, so `90`
  is `left` and `180` is `up`. Angles may be negative or decimal and wrap
  around at 360.
- `start` and `stop` are fractions of the distance across the image, in that
  direction. They default to `0` and `1`.

Default: none. Lays the color over the image, transparent before `start` and
reaching full opacity at `stop`. Swapping `start` and `stop` reverses the ramp,
and equal values make a hard edge. The directions follow the image as it is
displayed after rotating, flipping, and resizing. The image's transparency is
kept.

The values are positional, so to set `start` you also write a direction. An
empty value, such as `gradient=0.8,black,,0.5`, fails with `400`.

<!-- tabs-open -->

### URL

```text
/gradient=0.8,black,down,0.2,0.9/src/photos/beach.jpg
```

### Elixir

```elixir
ImagePipe.URL.group(builder,
  gradient: [opacity: 0.8, color: "black", direction: :down, start: 0.2, stop: 0.9]
)
```

<!-- tabs-close -->
