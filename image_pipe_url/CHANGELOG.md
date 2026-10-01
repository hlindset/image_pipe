# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

First release of the ImagePipe URL builder.

- Build typed processing plans and generate image URLs with explicit processing
  groups and output options.
- Validate processing options and compose named presets with request overrides.
- Sign URLs, set expiry, and encrypt source references.
- Generate URLs in applications that use an external image service, without
  libvips, NIFs, or image processing dependencies.

[Unreleased]: https://github.com/hlindset/image_pipe/commits/main/
