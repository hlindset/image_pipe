# Tag-driven lockstep release

Beads `image_plug-adu`. Draft for agreement; nothing here is implemented.

## Summary

Pushing a tag `vX.Y.Z` runs one release workflow. It checks that all three
projects declare `X.Y.Z`, builds and smoke-tests both server image variants for
amd64 and arm64, publishes `image_pipe_url` and then `image_pipe` to Hex, tags
the images on GHCR, and creates a GitHub release. `image_pipe_server` ships
only as an image.

## Findings

**Each `mix.exs` must keep a literal version.** A Hex package's `mix.exs` is
evaluated on the consumer's machine, so it can't read a `VERSION` file outside
the package directory. Keep `@version` in `image_pipe_url` and `image_pipe`,
give `image_pipe_server` a `@version` too, and extend the existing precommit
comparison to all three.

**`image_pipe` can't be packaged until `image_pipe_url` is on Hex.** `mix
hex.build` in `image_pipe` stops with "only Hex packages can be dependencies".
With `IMAGE_PIPE_PUBLISH=1`, `mix deps.get` resolves `image_pipe_url == X.Y.Z`
from Hex, so it must run after the first publish succeeds. `image_pipe_url`
already builds cleanly.

**Packages have no git dependencies.** Nothing else blocks a Hex build.

**`ex_doc` already expects the tag.** Both libraries set `source_ref:
"v#{@version}"`, so the tag scheme is fixed at `vX.Y.Z`.

## Workflow

`.github/workflows/release.yml`, triggered by `push: tags: ["v*.*.*"]`.

1. **Verify.** The tag minus `v` must equal all three versions, the tagged
   commit must be on `main`, where CI has already run the gate, and
   `CHANGELOG.md` must have a `## X.Y.Z` section for the release notes.
2. **Build images.** A matrix of `{base, vision} × {amd64, arm64}`, on
   `ubuntu-24.04` and `ubuntu-24.04-arm` (native, not QEMU: libvips compiles
   from source in the Dockerfile). Each job runs the existing smoke test, then
   pushes by digest only, with no tag. Cache scope per variant and arch:
   amd64 reads the cache Server image CI writes on `main`; nothing writes an
   arm64 cache on `main`, so a manual dry run there warms it.
3. **Publish Hex.** In a `release` environment holding `HEX_API_KEY`,
   `scripts/release_hex.exs` (an Elixir script using `Mix.install` for Req)
   publishes `image_pipe_url`, then `image_pipe` with `IMAGE_PIPE_PUBLISH=1`.
   Docs build with `--warnings-as-errors` and publish with each package. A
   manual run of the workflow, or `mise run release:hex --dry-run`, does the
   same without publishing.
4. **Tag images.** `docker buildx imagetools create` joins each variant's two
   digests into one manifest list and tags it `X.Y.Z`, `X.Y`, and `latest`
   (`-vision` suffixed for the vision variant). Add OCI labels for source,
   revision, version, and license.
5. **GitHub release.** Notes from `image_pipe/CHANGELOG.md`'s section for the
   version.

Images build before anything publishes because the build is the slow and
fallible part. A failure there leaves Hex untouched and only untagged digests
in GHCR. Tagging the images is cheap and comes after Hex, so a published
image always has its matching packages.

Only the release workflow gets `packages: write`; other workflows keep
`contents: read`.

## Failures

If `image_pipe` fails to publish after `image_pipe_url` succeeds, rerun the
failed job: the script skips a version that is already on Hex. Within Hex's revert window, `mix hex.publish --revert
X.Y.Z` is the manual undo. Never retag: a bad release is fixed with the next
patch version.

## Images build from tagged source

The Dockerfile keeps path dependencies. Building from the tagged source makes
the image independent of Hex timing and identical to what CI tested.

## Release procedure

Documented in the repository root `RELEASING.md`:

1. Bump `@version` in the three `mix.exs` files and add a `CHANGELOG.md`
   section; merge to `main`.
2. Tag the merge commit `vX.Y.Z` and push the tag.

## Decisions

Agreed: the server ships only as an image, a tag push triggers the release,
and `:edge` from `main` is out of scope. The vision image builds and passes
the smoke test on arm64 (local Docker on Apple silicon).

Open:

- **Approval gate:** whether the `release` environment requires a manual
  approval before Hex publishing.
