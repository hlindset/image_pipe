# Changelog

## 0.1.0

- Split URL building into the `image_pipe_url` package, which `image_pipe`
  depends on and releases in lockstep. Build plans and URLs with
  `ImagePipe.URL` and its `ImagePipe.URL.config/1`; the server configuration
  takes that value as `url:`, and `ImagePipe.run/4` and `ImagePipe.write/5`
  take the server configuration first.

- Updated Elixir/OTP tooling and the library and Fiddle dependencies. Migrated
  Image background options and Req connection settings, and replaced Vix Git
  pins with the upstream release containing the required fixes.

- Added Hex package metadata.
- Added product-neutral source adapters for local paths, HTTP(S), and
  S3-compatible object sources.
- Added documentation for installation, mounting,
  API URLs, support boundaries, cache behavior, and operational
  behavior.
- Consolidated image processing into one API request lifecycle and executor,
  with explicit `-` groups and fixed operation order. Added API geometry,
  effects, encoder and color controls, concealed sources, and info/BlurHash output.
- Retired the imgproxy, IIIF, and TwicPics URL APIs. Selected imgproxy image
  comparisons remain as test references for shared behavior.
- Added the license file.
