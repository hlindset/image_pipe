# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- The `IPS_CONFIG_TOML` environment variable holds the whole TOML
  configuration, for platforms that can't mount a configuration file. `IPS_`
  setting variables override it as they override the file. Setting both
  `IPS_CONFIG` and `IPS_CONFIG_TOML` is an error.
- SVG originals and SVG watermarks render like other images. An SVG renders
  straight at the size the request needs, so it stays sharp at any size, and
  a resize can make it larger than its own size without `enlarge`. Without a
  `format` or a negotiated one, the result is a PNG.
- `[processing.svg]` configures SVG rendering: `font_dirs` and
  `fallback_family` for the fonts SVG text renders in (mount a font
  directory into the container, since no system fonts are used), and
  `max_bytes`, `max_render_work`, and `max_render_pixels` to limit the work
  an SVG can cause. A `font_dirs` entry that doesn't exist, or a file in it
  that isn't a font, stops the server from starting.
- Logs and traces have an `image_pipe.source.svg_render` span for each SVG
  rendered, with its own and rendered sizes, the estimated work, and the
  limit that rejected an SVG.

### Changed

- Cached images from earlier versions miss once, since cache keys now
  include the SVG renderer and the fonts. Changing the fonts or the
  fallback family makes cached images miss again.
- The server uses about 140 MiB less memory: it loads its code when it first
  needs it instead of all at startup. Set `RELEASE_MODE=embedded` to load
  everything at startup.
- Before it reports ready, the server processes a small image in each output
  format, so the first requests don't wait for the image-processing code to
  load or an encoder to start. `/health/ready` now answers `503` until then, including on the
  separate `health_port` listener.
- Images process faster, PNG most of all. The Docker images now ship zlib-ng
  2.3.3, libjpeg-turbo 3.2.0 and libpng 1.6.59 in place of Debian's zlib,
  libjpeg-turbo and libpng. Across a set of typical requests, latency dropped
  by about a quarter, and by more than half for some PNG resizes.
- The server handles about 5–10% more images per second when the container
  has a CPU limit: the Erlang VM's schedulers no longer spin while they wait
  for work, which took CPU that image processing needed.

## [0.1.0] - 2026-10-09

### Added

First release of the standalone ImagePipe server.

- Run a dedicated HTTP image service from the published Docker images at
  `ghcr.io/hlindset/image_pipe_server`, or build it as a Mix release. Configure
  it through TOML and environment variables, without writing an Elixir
  application.
- Configure file, HTTP(S), and S3 sources, filesystem caches, signing keys,
  presets, and processing limits. Load secrets from mounted files.
- Serve images under a configurable mount path, with health checks, request
  IDs, optional bearer authentication, logging, and OpenTelemetry export.
- Choose a base image or a vision image with bundled face and object detection
  models.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/image_pipe_server-v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/image_pipe_server-v0.1.0
