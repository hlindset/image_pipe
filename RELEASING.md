# Releasing

`image_pipe` and `image_pipe_url` are released together at the same version.
`image_pipe` pins `image_pipe_url` with `==`, and `mise run precommit` fails
when the two `@version` values differ.

1. Set the same `@version` in `image_pipe_url/mix.exs` and `image_pipe/mix.exs`,
   and update `image_pipe/CHANGELOG.md`.
2. Publish `image_pipe_url` first, from `image_pipe_url/`:

   ```sh
   mise exec -- mix hex.publish
   ```

3. Publish `image_pipe` from `image_pipe/`. In development it depends on the
   sibling checkout by path, which a Hex package cannot carry;
   `IMAGE_PIPE_PUBLISH=1` switches it to the Hex release from step 2:

   ```sh
   IMAGE_PIPE_PUBLISH=1 mise exec -- mix deps.get
   IMAGE_PIPE_PUBLISH=1 mise exec -- mix hex.publish
   ```

   The `deps.get` records the Hex dependency in `image_pipe/mix.lock`. Discard
   that change afterwards rather than committing it.
