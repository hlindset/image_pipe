# ImagePipeFiddle

The Fiddle edits and previews ImagePipe's path API. Browser state uses
`/edit/...` URLs, while image and text previews run through `/image/...`.

Controls generate URLs, and opening a saved URL restores its values. A group
selector edits `-` requests; output settings apply to the whole request. The
Advanced section allows direct path editing. See [the Fiddle guide](../image_pipe/docs/fiddle.md)
for sources, tracing, and sidecar setup.

Crop and cover resize share the Gravity controls. Canvas modes require both
resize dimensions, so enabling a canvas sets automatic dimensions to pixels;
switching either dimension back to auto turns the canvas off. PNG palette
size uses the bit-depth selector.

The Protection control uses `/image-signed/...` for signed previews and can
conceal the source. Fixed demo keys stay on the server; each option change
requests a fresh protected path.

`display-p3.png` and `rgba16.png` in `priv/static/images/` are
copies of the generated color fixtures `icc_p3.png` and `rgba16.png` from
`../image_pipe/test/support/image_pipe/test/sources/`. They retain
their embedded profile and bit depth so the examples exercise those paths.

The request editor can use local files, the optional S3 proxy, and HTTP
against the running demo. The loopback HTTP adapter is enabled in
development and tests; it is disabled in the base configuration used by
production. HTTP samples follow the browser's loopback origin and port.

## Run locally

From the repository root:

```sh
mise install        # install the toolchain
mise run setup      # install dependencies
mise run fiddle     # start Phoenix and Vite
```

Open [localhost:4000](http://localhost:4000).

Run `mise run precommit:fiddle` for the library and Fiddle checks. The frontend
uses the stable TypeScript 7 native compiler through `@typescript/native`.
The `typescript` dependency aliases `@typescript/typescript6` because
`svelte-check` still needs its JavaScript compiler API, following the
[TypeScript 7 migration guidance](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/).
