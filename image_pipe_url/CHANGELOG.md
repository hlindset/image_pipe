# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- A URL's `anchor-offset`, `extend-at`, or `extend-offset` no longer
  replaces the crop target or canvas from a preset or the request defaults,
  and its `unset` removes only that option. Before, `anchor-offset=5,5`
  dropped a preset's `anchor`, and `extend-at=unset` dropped its `extend`.
- A `trim` tolerance above `2147483647` is rejected, both in a URL and by
  `ImagePipe.URL.group/2`.

### Fixed

- Checking a URL with `:validate_against` applies the request defaults to
  the URL's first group, as the server does, even when that group holds
  only `unset` options or names a preset the check doesn't know. Before,
  the defaults were checked with the next group, so the check could
  disagree with the server.

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

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/hlindset/image_pipe/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/hlindset/image_pipe/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
