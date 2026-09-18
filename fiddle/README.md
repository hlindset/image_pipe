# ImagePipeFiddle

The Fiddle edits and previews ImagePipe's native path API. Browser state uses
`/native/...` URLs, while image and text previews run through `/native-image/...`.

The Protection control can route a preview through the signing-required
`/native-signed/...` mount. Its Signed mode binds the complete native request,
while Signed + concealed source also replaces the source identifier with an
authenticated encrypted token. The fixed keys are demo-only and stay on the
Fiddle server; browser URLs retain only the selected mode and editable request
state, so every option change asks the server for a fresh protected path.

The native examples include metadata retention, ICC profile conversion, and
16-bit output. `display-p3.png` and `rgba16.png` in `priv/static/images/` are
copies of the generated color fixtures `icc_p3.png` and `rgba16.png` from
`../test/support/image_pipe/test/sources/`. They retain
their embedded profile and bit depth so the examples exercise those paths.

Source-info JSON and BlurHash examples render as text in the preview. Download
examples exercise response filenames and attachments; the cachebuster example
selects a fresh storage entry while retaining the representation's ETag.

The native request editor can use local files, the optional S3 proxy, and HTTP
against the running demo. The loopback HTTP adapter is enabled in
development and tests; it is disabled in the base configuration used by
production. HTTP samples follow the browser's loopback origin and port.

To start your Phoenix server:

* Run `mix setup` to install and setup dependencies
* Start Phoenix endpoint with `mix phx.server` or inside IEx with `iex -S mix phx.server`

Now you can visit [`localhost:4000`](http://localhost:4000) from your browser.

Ready to run in production? Please [check our deployment guides](https://hexdocs.pm/phoenix/deployment.html).

## Learn more

* Official website: https://www.phoenixframework.org/
* Guides: https://hexdocs.pm/phoenix/overview.html
* Docs: https://hexdocs.pm/phoenix
* Forum: https://elixirforum.com/c/phoenix-forum
* Source: https://github.com/phoenixframework/phoenix
