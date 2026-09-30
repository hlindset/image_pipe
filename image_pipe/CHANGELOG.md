# Changelog

## Unreleased

- Updated Elixir/OTP tooling and the library and Fiddle dependencies. Migrated
  Image background options and Req connection settings, and replaced Vix Git
  pins with the upstream release containing the required fixes.

- Prepared package metadata for release evaluation.
- Added product-neutral source adapters for local paths, HTTP(S), and
  S3-compatible object sources.
- Added top-level release-readiness documentation for installation, mounting,
  API URLs, support boundaries, cache behavior, and operational
  behavior.
- Consolidated image processing into one API request lifecycle and executor,
  with explicit `-` groups and fixed operation order. Added API geometry,
  effects, encoder and color controls, concealed sources, and info/BlurHash output.
- Retired the imgproxy, IIIF, and TwicPics URL APIs. Selected imgproxy image
  comparisons remain as test references for shared behavior.
- Added the license file.
