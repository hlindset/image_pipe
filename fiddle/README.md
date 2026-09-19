# ImagePipeFiddle

The Fiddle edits and previews ImagePipe's path API. Browser state uses
`/native/...` URLs, while image and text previews run through `/native-image/...`.

The sidebar provides sliders, numeric inputs, toggles, color pickers, and a
clickable focal-point preview for resize, crop, gravity, orientation, trim,
canvas, padding, effects, and output settings. Controls generate URLs;
opening a saved URL fills the controls with its values. Requests with `then`
groups have a group selector, while output settings apply to the whole request.
Examples load into the same controls. The collapsed Advanced section allows
direct path editing, and control changes preserve other options.

Crop and cover resize share the Gravity controls. Canvas modes require both
resize dimensions, so enabling a canvas sets automatic dimensions to pixels;
switching either dimension back to auto turns the canvas off. PNG palette
size uses the bit-depth selector.

The Protection control can route a preview through the signing-required
`/native-signed/...` mount. Its Signed mode binds the complete request,
while Signed + concealed source also replaces the source identifier with an
authenticated encrypted token. The fixed keys are demo-only and stay on the
Fiddle server; browser URLs retain only the selected mode and editable request
state, so every option change asks the server for a fresh protected path.

The examples include metadata retention, ICC profile conversion, and
16-bit output. `display-p3.png` and `rgba16.png` in `priv/static/images/` are
copies of the generated color fixtures `icc_p3.png` and `rgba16.png` from
`../test/support/image_pipe/test/sources/`. They retain
their embedded profile and bit depth so the examples exercise those paths.

Source-info JSON and BlurHash examples render as text in the preview. Download
examples exercise response filenames and attachments; the cachebuster example
selects a fresh storage entry while retaining the representation's ETag.

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
