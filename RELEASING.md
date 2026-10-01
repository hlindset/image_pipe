# Releasing

`image_pipe_url`, `image_pipe`, and `image_pipe_server` share one version.
`image_pipe` pins `image_pipe_url` with `==`, and `scripts/check-versions.sh`,
run by `mise run precommit`, fails when the three `@version` values differ.

## Release a version

1. Set the same `@version` in `image_pipe_url/mix.exs`, `image_pipe/mix.exs`,
   and `image_pipe_server/mix.exs`. In `image_pipe/CHANGELOG.md`, add the release
   notes under a `## X.Y.Z` heading (a date may follow the version).
   Merge to `main`.
2. Tag the merge commit and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

The tag starts the [Release workflow](.github/workflows/release.yml):

1. It checks that the tag matches all three versions, is on `main`, and has
   changelog notes.
2. It builds the `image_pipe_server` base and vision images for amd64 and
   arm64, smoke-tests each, and pushes them to GHCR untagged.
3. It publishes `image_pipe_url` and then `image_pipe` to Hex with their docs,
   in the `release` environment, which holds the `HEX_API_KEY` secret.
4. It tags the images `ghcr.io/hlindset/image_pipe_server:X.Y.Z`, `X.Y`, and
   `latest`, with a `-vision` suffix for the vision variant. A pre-release
   version gets only its own tag.
5. It creates the GitHub release from the changelog notes.

A failure before step 3 leaves only untagged images. GHCR creates the package
private on its first push; make it public once in the package settings.

Never move a tag. Fix a bad release with the next patch version. Within Hex's
revert window, `mix hex.publish --revert X.Y.Z` in the package directory
withdraws a version.

## Dry run

Run the Release workflow by hand from any branch. It builds and smoke-tests
every image and checks the Hex packages without publishing. A run on `main`
also warms the arm64 layer cache that the next release reads.

Check the Hex packages alone locally with:

```sh
mise run release:hex --dry-run
```

A dry run builds both packages and their docs, failing on documentation
warnings, without publishing. Until `image_pipe_url` at the new version is on
Hex, `image_pipe` can't resolve it, so its check stops just short of that one
dependency.

## Rerunning

Rerun the failed jobs. `scripts/release_hex.exs` skips a version that is
already on Hex, so a rerun after `image_pipe_url` was published continues with
`image_pipe`. Image digests stay untagged until the Hex packages are published.
