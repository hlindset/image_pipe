# Releasing

`image_pipe_url` and `image_pipe` release together at one version, and
`image_pipe` pins `image_pipe_url` with `==`. `image_pipe_server` shares their
major.minor version and releases its patch versions on its own, so a server
fix ships new images without a Hex release. `scripts/check-versions.sh`, run
by `mise run precommit`, fails when the versions break these rules.

Each project keeps its own release notes:

- [ImagePipe](image_pipe/CHANGELOG.md): processing, sources, and library APIs.
- [ImagePipe URL](image_pipe_url/CHANGELOG.md): plans, URL generation, and signing.
- [ImagePipe server](image_pipe_server/CHANGELOG.md): service configuration and deployment.

## Update the changelogs

Each changelog follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Add notes under `## [Unreleased]` as changes land. Start the note for a
breaking change with `**Breaking:**` and say what users must change. Before
1.0, a release with a breaking change bumps the minor version.

To release a version, move the `Unreleased` notes under
`## [X.Y.Z] - YYYY-MM-DD`, using the release date. Group notes under `Added`,
`Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`, and include only
categories with entries. Add a version link to the comparison with the
previous release, or to the tag for the first release. Update the
`Unreleased` link to compare the new tag with `HEAD`. Library links use
`vX.Y.Z` tags, and server links use `image_pipe_server-vX.Y.Z` tags.

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

The tag starts the [Library release workflow](.github/workflows/release.yml):

1. It checks that the tag matches both library versions, is on `main`, and
   has notes in both changelogs.
2. It publishes `image_pipe_url` and then `image_pipe` to Hex with their docs,
   in the `release` environment, which holds the `HEX_API_KEY` secret.
3. It creates the GitHub release from both changelogs, grouped by project.

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

## Try a release without publishing

Run either release workflow by hand from any branch. Neither publishes
anything.

- The Library release workflow builds and checks the Hex packages.
- The Server release workflow tests, builds, and smoke-tests every image.
  It builds against Hex when `@image_pipe_version` is published there, and
  against the sibling projects otherwise. The run summary says which. A run
  on `main` also warms the layer caches that the next release reads.

Check the Hex packages alone locally with:

```sh
mise run release:hex --dry-run
```

A dry run builds both packages and their docs, failing on documentation
warnings, without publishing. Until `image_pipe_url` at the new version is on
Hex, `image_pipe` can't resolve it, so its check stops just short of that one
dependency.

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
