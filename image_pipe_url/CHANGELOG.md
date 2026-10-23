# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.4.0] - 2026-10-23

### Added

- With `:validate_against`, `ImagePipe.URL.validate/1` warns about a `crop`
  or `region` that covers the whole frame, as an `:inert_option` issue with
  `detail: :full_frame`. It also warns about the options only that crop or
  region made useful, such as `anchor`.

### Changed

- Parsing a URL takes less time, most of all for a URL without presets or
  `unset` when no request defaults are set.
- A `watermark_source:` loses an optional leading `/`, as the main source
  does, so its `wm-src64` value and its deterministic `wm-enc` token change.
- A URL's `anchor-offset`, `extend-at`, or `extend-offset` no longer
  replaces the crop target or canvas from a preset or the request defaults,
  and its `unset` removes only that option. Before, `anchor-offset=5,5`
  dropped a preset's `anchor`, and `extend-at=unset` dropped its `extend`.
- A `trim` tolerance above `2147483647` is rejected, both in a URL and by
  `ImagePipe.URL.group/2`.
- Errors from parsing a URL state the accepted range for sizes, offsets,
  `pad`, `wm-gap`, `dpr`, `zoom`, `crop-ratio`, `detect`, `blur`,
  `progressive-blur`, `sharpen`, `pixelate`, `contrast`, `saturation`, and
  the `trim` tolerance, and show which `gradient` values are optional.
- An invalid value given to the URL builder appears in its error, with the
  accepted range for numbers, as in `invalid value for :dpr option:
  expected a number above 0, at most 2147483647, got: 0`. An invalid source
  isn't repeated in its error.
- **Breaking:** The `:presets` in `:validate_against` must be a map with
  string keys. Change a list of `{name, fragment}` pairs to a map such as
  `%{"card" => "w=400"}`. `ImagePipe.URL.config/1` raises an
  `ArgumentError` that names `:presets` for any other value, instead of a
  `Protocol.UndefinedError`.
- A `region` whose x or y is `0pct` gives the same plan as one written with
  `0`.
- `detect=all:3`, one weight for every class, gives the same plan as
  `detect=all`.
- `crop=100pct,100pct` without `crop-ratio`, and `region=0,0,100pct,100pct`,
  give the same plan as the request without them.
- `autoquality` and `max-bytes` are reported as ignored options with
  `format=webp` and lossless `webp-options`, as with `format=png`.
- Checking and decoding the percent escapes of a `src` source takes less
  time, up to about 0.5 ms less for an 8 KB source.

### Removed

- **Breaking:** `request_watermarks` in `validate_against`, and the
  `:watermark_source_disabled` issue. Servers accept every watermark source
  that a configured source serves. Remove the option from `validate_against`.
- **Breaking:** `mount:` on `ImagePipe.URL.Helpers`. Start an instance with
  the mount's URL settings and pass its name as `instance:`.

### Fixed

- The URL builder's validation against a server's presets resolves them
  the way the server does: a value that a later layer unsets or replaces no
  longer removes what it would have replaced, and a preset that names other
  presets gives the same result as listing them.
- `ImagePipe.URL.url/3` returns `{:error, :invalid_source}` for a source
  that is just `/` or holds a NUL byte, which the server refuses.
  `ImagePipe.URL.group/2` rejects such a `watermark_source:`.
- Checking a URL with `:validate_against` applies the request defaults to
  the URL's first group, as the server does, even when that group holds
  only `unset` options or names a preset the check doesn't know. Before,
  the defaults were checked with the next group, so the check could
  disagree with the server.
- A preset in `:validate_against` with a group holding only `unset`
  options is a pipeline preset, as on the server, so adding other options
  to it is an error, and a first group like that clears the request
  defaults. Before, the check dropped that group.
- An issue that `validate/1` reports with `:validate_against` names the
  group as the builder numbers it. Before, when a group held only `unset`
  options, issues in later groups named the group before theirs.
- With `preset_lookup: true`, `ImagePipe.URL.validate/1` reports a
  conflict between two options the plan sets, such as `quality:` with
  `autoquality: true`, even when the plan names a preset missing from
  `:presets`, and `ImagePipe.URL.url/3` returns
  `{:error, {:invalid_request, issues}}`. Before, `ImagePipe.URL.url/3`
  built a URL the server rejects with `400`.

## [0.3.0] - 2026-10-18

### Added

- The `kernel` resize option (`resize: [kernel: :nearest]` in the builder)
  sets the filter a group's resize uses: `nearest`, `linear`, `cubic`,
  `mitchell`, `lanczos2`, `lanczos3` (the default), `mks2013`, or `mks2021`.
- The `priority` request option (`priority: :low` in the builder) lets a
  request wait for spare capacity in the server's processing pool.

### Changed

- **Breaking:** `ImagePipe.URL.config/1` raises `ArgumentError` when a preset
  or the request defaults in `:validate_against` set options that can't be
  combined, such as `anchor=top/detect=face` or `q=80/autoquality=50`. It also
  raises when they name a watermark that the `:watermarks` list leaves out, or
  use `wm-src64` or `wm-enc` with `request_watermarks: false`. A server
  running the matching `image_pipe` release fails at startup with the same
  presets. Remove one of the conflicting options, or the watermark option,
  from the server's presets and the builder's copy.

### Fixed

- `ImagePipe.URL.new/1` rejects `filename: "unset"` and `cachebuster: "unset"`
  instead of building a URL without them. In a URL, `unset` clears an option.
- `ImagePipe.URL.group/2` rejects the detection class `"unset"`, which URLs
  don't accept.
- A float of 2^53 or more, such as `rotate: 1.0e300` or a trim tolerance of
  `1.0e308`, keeps its exact value in the built URL. The URL used to carry a
  nearby whole number instead, so `rotate: 1.0e300` built a URL that rotated
  by 280 degrees rather than 0.

## [0.2.0] - 2026-10-13

### Removed

- **Breaking:** `ImagePipe.Plan.Source.Path`, `ImagePipe.Plan.Source.URL`, and
  `ImagePipe.Plan.Source.Object`. They are now `ImagePipe.Source.Path`,
  `ImagePipe.Source.URL`, and `ImagePipe.Source.Object` in `image_pipe`, whose
  custom source adapters receive them.
- The dependency on `mime`. The package depends only on `nimble_options` and
  `color` at runtime.

## [0.1.0] - 2026-10-09

### Added

First release of the ImagePipe URL builder.

- Build typed processing plans and generate image URLs with explicit processing
  groups and output options.
- Validate processing options, reference named presets with request overrides,
  and optionally check plans against the serving mount's presets.
- Sign URLs, set expiry, and encrypt source references.
- Generate URLs in applications that use an external image service, without
  libvips, NIFs, or image processing dependencies.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/hlindset/image_pipe/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/hlindset/image_pipe/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/hlindset/image_pipe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
