# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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
