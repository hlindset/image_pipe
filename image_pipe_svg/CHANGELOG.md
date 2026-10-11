# Changelog

This changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Releases use [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Rendering SVG for ImagePipe with resvg, through a precompiled native
  library. Rendering never reads files or opens connections, draws text only
  in the fonts it's given, and accepts embedded PNG, JPEG, GIF, and WebP
  images and SVGs nested two levels deep. It bounds how far entities and
  `<use>` can expand before parsing, and estimates the cost of a render
  before it renders, so ImagePipe can reject an SVG that's too expensive.
