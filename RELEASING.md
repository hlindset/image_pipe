# Releasing

`image_pipe_url`, `image_pipe`, and `image_pipe_server` share one version.
`image_pipe` pins `image_pipe_url` with `==`, and `scripts/check-versions.sh`,
run by `mise run precommit`, fails when the three `@version` values differ.

## Release a version

1. Set the same `@version` in `image_pipe_url/mix.exs`, `image_pipe/mix.exs`,
   and `image_pipe_server/mix.exs`, update `image_pipe/CHANGELOG.md`, and merge
   to `main`.
2. Tag the merge commit and push the tag:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

The tag starts the [Release workflow](.github/workflows/release.yml). It checks
that the tag matches all three versions and is on `main`, then publishes
`image_pipe_url` and `image_pipe` to Hex with their docs. Publishing runs in the
`release` environment, which holds the `HEX_API_KEY` secret.

Never move a tag. Fix a bad release with the next patch version. Within Hex's
revert window, `mix hex.publish --revert X.Y.Z` in the package directory
withdraws a version.

## Dry run

Run the Release workflow by hand from any branch, or locally:

```sh
mise run release:hex --dry-run
```

A dry run builds both packages and their docs, failing on documentation
warnings, without publishing. Until `image_pipe_url` at the new version is on
Hex, `image_pipe` can't resolve it, so its check stops just short of that one
dependency.

## Rerunning

`scripts/release_hex.exs` skips a version that is already on Hex. If
`image_pipe` fails after `image_pipe_url` is published, rerun the failed job.
