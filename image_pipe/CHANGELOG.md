# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

First release of ImagePipe, with image processing powered by
[elixir-image/image](https://github.com/elixir-image/image),
[Vix](https://github.com/akash-akya/vix), and libvips.

- Serve transformed images on demand from Phoenix or any Plug application
  through `ImagePipe.Plug`. Reuse the same processing plans and configuration
  for uploads, files, and background jobs through the Elixir API.
- Run a dedicated image service with `image_pipe_server`, packaged as a Docker
  image or Mix release. Configure it through TOML and environment variables,
  without writing an Elixir application.
- Build URLs with `image_pipe_url` without the image processing runtime,
  including presets, signatures, expiry, and source encryption.
- Read originals from local files, HTTP(S), S3-compatible storage, or custom
  source adapters.
- Compose resizing, cropping, orientation, effects, and watermarks in explicit
  processing groups, with optional face and object detection.
- Encode images with format negotiation, quality controls, byte budgets, and
  color-profile policies. Generate BlurHash, LQIP CSS, and image-info JSON.
- Configure input and output caches, conditional HTTP responses, streamed
  delivery, request safety limits, and processing concurrency. Observe requests
  through telemetry, logging, and tracing.

[Unreleased]: https://github.com/hlindset/image_pipe/commits/main/
