# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-13

### Added

- Rendering SVG for ImagePipe with resvg, through a precompiled native
  library. Rendering never reads files or opens connections, draws text only
  in the fonts it's given, and accepts embedded PNG, JPEG, GIF, and WebP
  images and SVGs nested two levels deep. It bounds how far entities and
  `<use>` can expand, and how much text it lays out, before parsing, and
  estimates the cost of a render before it renders, so ImagePipe can reject
  an SVG that's too expensive.

[Unreleased]: https://github.com/hlindset/image_pipe/compare/image_pipe_svg-v0.1.0...HEAD
[0.1.0]: https://github.com/hlindset/image_pipe/releases/tag/image_pipe_svg-v0.1.0
