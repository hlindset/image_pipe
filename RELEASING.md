# Releasing

`image_pipe_url` and `image_pipe` release together at one version, and
`image_pipe` pins `image_pipe_url` with `==`. `image_pipe_server` shares their
major.minor version and releases its patch versions on its own, so a server
fix ships new images without a Hex release. `scripts/check-versions.sh`, run
by `mise run precommit`, fails when the versions break these rules.
`image_pipe_svg` has its own version and release cadence, since each release
rebuilds its precompiled NIFs.

Each project keeps its own release notes:

- [ImagePipe](image_pipe/CHANGELOG.md): processing, sources, and library APIs.
- [ImagePipe URL](image_pipe_url/CHANGELOG.md): plans, URL generation, and signing.
- [ImagePipe server](image_pipe_server/CHANGELOG.md): service configuration and deployment.
- [ImagePipe SVG](image_pipe_svg/CHANGELOG.md): SVG rendering.

## Update the changelogs

Each changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Add notes under `## [Unreleased]` as changes land. Start the note for a
breaking change with `**Breaking:**` and say what users must change. Before
1.0, a release with a breaking change bumps the minor version.

Notes describe the difference from the last release, not the history between
commits. When a change revises, extends, or reverts something added since the
last release, edit or remove its `Unreleased` note instead of adding another.
A feature added and removed before a release gets no note.

To release a version, move the `Unreleased` notes under
`## [X.Y.Z] - YYYY-MM-DD`, using the release date. Group notes under `Added`,
`Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`, and include only
categories with entries. Add a version link to the comparison with the
previous release, or to the tag for the first release. Update the
`Unreleased` link to compare the new tag with `HEAD`. Library links use
`vX.Y.Z` tags, server links use `image_pipe_server-vX.Y.Z` tags, and SVG
package links use `image_pipe_svg-vX.Y.Z` tags.

## Release the libraries

1. Set the same `@version` in `image_pipe_url/mix.exs` and
   `image_pipe/mix.exs`, and [update both changelogs](#update-the-changelogs).
   When only one library changed, the unchanged one's notes say, under
   `Changed`, "Released with `image_pipe` X.Y.Z." or "Released with
   `image_pipe_url` X.Y.Z.", naming the library that changed. Merge to
   `main`.
2. Tag the merge commit and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

`image_pipe` depends on `image_pipe_svg`, which releases on its own, so a
version matching `image_pipe`'s requirement must already be on Hex. Otherwise
the release stops before publishing `image_pipe`. See
[Release the SVG package](#release-the-svg-package).

The tag starts the [Library release workflow](.github/workflows/release.yml):

1. It checks that the tag matches both library versions, is on `main`, and
   has notes in both changelogs.
2. It waits for a maintainer to approve the `release` environment on the
   run's page. Then it publishes `image_pipe_url` and then `image_pipe` to
   Hex with their docs.
3. It creates the GitHub release from both changelogs, grouped by project.

The `release` environment holds the `HEX_API_KEY` secret. It accepts only
jobs from the refs in its deployment rules: the `v*.*.*` and
`image_pipe_svg-v*.*.*` tags, and `main` for
[republishing docs](#fix-the-docs-of-a-release). A new tag prefix that
publishes to Hex needs its own rule in the environment's settings.

Server images don't change. To ship the new libraries in images, set
`@image_pipe_version` in the next server release.

## Release the server

When a push to `main` touches the server or library code, the Server CI job
"Releasable without a library release" compiles and tests the server against
`@image_pipe_version` from Hex. If it shows a "Not releasable" warning,
release the libraries first.

1. Set `@version` in `image_pipe_server/mix.exs`. To ship newer libraries,
   also set `@image_pipe_version` to their version.
   [Update the server changelog](#update-the-changelogs) and merge to `main`.
   When `@image_pipe_version` changes:
   - Add a note under `Changed` that names the new library version and
     links to its notes in the [library changelog](image_pipe/CHANGELOG.md),
     such as
     ``Uses `image_pipe` [0.2.0](https://github.com/hlindset/image_pipe/blob/v0.2.0/image_pipe/CHANGELOG.md).``
   - Check `bd list --label server-changelog --status open` for library
     changes server users see. Add the entries of those that the new
     library version includes, and close those beads.
2. Tag the merge commit and push the tag:

   ```sh
   git tag image_pipe_server-vX.Y.Z
   git push origin image_pipe_server-vX.Y.Z
   ```

The tag starts the [Server release workflow](.github/workflows/release-server.yml):

1. It checks that the tag matches the server version, is on `main`, and has
   notes in the server changelog.
2. It runs the server tests against `image_pipe` `@image_pipe_version` from
   Hex. The tests job fails if the server needs library code that isn't
   released yet. Release the libraries first.
3. It builds the base and vision images for amd64 and arm64 against the same
   Hex packages, smoke-tests each, and pushes them to GHCR untagged.
4. It waits for a maintainer to approve the `release-server` environment on
   the run's page. Then it tags the images
   `ghcr.io/hlindset/image_pipe_server:X.Y.Z`, `X.Y`, and `latest`, with a
   `-vision` suffix for the vision variant. A pre-release version gets only
   its own tag.
5. It creates the GitHub release from the server changelog, and names the
   library version it was built with.

A failure or an unapproved run before step 4 leaves only untagged images. GHCR creates
the package private on its first push. Make it public once in the package
settings.

## Release the SVG package

1. Set `@version` in `image_pipe_svg/mix.exs`,
   [update its changelog](#update-the-changelogs), and merge to `main`.
   When the release changes how an SVG renders, other than by upgrading
   resvg, also raise `@render_revision` in
   `image_pipe_svg/lib/image_pipe/svg.ex`, so cached renders miss. When it
   changes the parsing code or upgrades resvg, run each fuzz target for 20
   minutes first, and fix what they find
   ([fuzzing the SVG parser](image_pipe_svg/native/image_pipe_svg_nif/fuzz/README.md)).
2. Tag the merge commit and push the tag:

   ```sh
   git tag image_pipe_svg-vX.Y.Z
   git push origin image_pipe_svg-vX.Y.Z
   ```

The tag starts the [SVG package release workflow](.github/workflows/release-svg.yml):

1. It checks that the tag matches the package version, is on `main`, and has
   notes in the changelog.
2. It builds the NIF for every target and NIF version.
3. It creates the GitHub release from the changelog, with the NIFs attached.
   The published package downloads them from there.
4. It waits for a maintainer to approve the `release` environment on the
   run's page. Then it downloads the NIFs' checksums and publishes
   `image_pipe_svg` to Hex. Until then, the GitHub release has no Hex
   package.

When `image_pipe` needs the new version, raise its `image_pipe_svg`
requirement in a library release. Library and server releases resolve
`image_pipe_svg` from Hex, so a version matching their requirements must be on
Hex before either is released.

## Release a new minor version

1. Set all three `@version` values and `@image_pipe_version` to `X.Y.0`,
   [update the three changelogs](#update-the-changelogs), and merge to
   `main`.
2. Push `vX.Y.0` and wait for the Library release workflow to finish.
3. Push `image_pipe_server-vX.Y.0`.

If the server tag goes out before the libraries are on Hex, the tests job
fails before any image is built. Rerun the failed jobs once the libraries are
published.

## Fix a bad release

Never move a tag. Fix a bad release with the next patch version. Within Hex's
revert window, `mix hex.publish --revert X.Y.Z` in the package directory
withdraws a library version.

## Fix the docs of a release

HexDocs for `image_pipe_url` and `image_pipe` can be republished without a
new release. The server guides are `image_pipe` extras, so they publish with
it. Docs built from `main` would describe unreleased changes, so build them
from the release tag plus the fixes:

1. Merge the fix to `main` as usual.
2. Make a `docs/vX.Y.Z` branch from the `vX.Y.Z` tag, or reuse it, and
   cherry-pick the fix onto it. Push the branch.
3. Run the [Library docs workflow](.github/workflows/release-docs.yml) from
   `main` with that branch as `ref`. Without `publish`, it only builds the
   docs. With `publish`, it waits for a maintainer to approve the `release`
   environment, then replaces the docs of both packages on HexDocs.

The workflow checks that the ref's version is on Hex and that only Markdown
files and `image_pipe/docs/assets/` changed since the tag. A fix to a
`@moduledoc`, `@doc`, or the ExDoc configuration changes code, so it waits
for the next release.

## Try a release without publishing

Run any release workflow by hand from any branch. None publishes anything.

- The Library release workflow builds and checks the Hex packages.
- The SVG package release workflow builds every NIF. It also runs on each
  pull request that changes the NIF crate.
- The Server release workflow tests, builds, and smoke-tests every image.
  It builds against Hex when `@image_pipe_version` is published there, and
  against the sibling projects otherwise. The run summary says which. A run
  on `main` also warms the layer caches that the next release reads.

Check the Hex packages alone locally with:

```sh
mise run release:hex --dry-run
```

A dry run builds both packages and their docs, failing on documentation
warnings, without publishing. Until `image_pipe_url` at the new version and a
matching `image_pipe_svg` are on Hex, `image_pipe` can't resolve them, so its
check builds from the sibling projects and stops just short of those
dependencies.

Build the server against the Hex libraries locally by setting
`IMAGE_PIPE_LIBS=hex`, for `mix` in `image_pipe_server/` or as a Docker build
argument:

```sh
docker build -f image_pipe_server/Dockerfile --build-arg IMAGE_PIPE_LIBS=hex -t image_pipe_server .
```

## Rerun a failed release

Rerun the failed jobs. `scripts/release_hex.exs` skips a version that is
already on Hex, so a rerun after `image_pipe_url` was published continues with
`image_pipe`. Images stay untagged until every image is built and
smoke-tested.
