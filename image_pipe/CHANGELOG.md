# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-09

### Added

First release of ImagePipe, with image processing powered by
[elixir-image/image](https://github.com/elixir-image/image),
[Vix](https://github.com/akash-akya/vix), and libvips.

- Serve transformed images on demand from Phoenix or any Plug application
  through `ImagePipe.Plug`. Reuse the same processing plans and configuration
  for uploads, files, and background jobs through the Elixir API.
- Read originals from local files, HTTP(S), S3-compatible storage, or custom
  source adapters.
- Compose resizing, cropping, orientation, effects, and watermarks in explicit
  processing groups, with optional face and object detection, or your own
  detector.
- Define reusable presets and request defaults in your configuration,
  statically or through a host preset lookup backed by a database or cache.
- Encode JPEG, PNG, WebP, and AVIF, with format negotiation, quality controls,
  byte budgets, and color-profile policies. Automatic quality gives each image
  the lowest quality that still looks as good as a target you choose. Generate
  BlurHash, LQIP CSS, and image-info JSON.
- Configure input and output caches, conditional HTTP responses, streamed
  delivery, request safety limits, and processing concurrency. Observe requests
  through telemetry, logging, and tracing.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
