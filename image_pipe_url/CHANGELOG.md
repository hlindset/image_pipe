# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/hlindset/image_pipe/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/v0.1.0
