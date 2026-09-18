# ImagePipeFiddle

The native examples include metadata retention, ICC profile conversion, and
16-bit output. `display-p3.png` and `rgba16.png` in `priv/static/images/` are
copies of the generated color fixtures `icc_p3.png` and `rgba16.png` from
`../test/support/image_pipe/test/imgproxy_differential/sources/`. They retain
their embedded profile and bit depth so the examples exercise those paths.

Source-info JSON and BlurHash examples render as text in the preview. Download
examples exercise response filenames and attachments; the cachebuster example
selects a fresh storage entry while retaining the representation's ETag.

Both providers share the source selector: local files, the optional S3 proxy,
and HTTP against the running demo. The loopback HTTP adapter is enabled in
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
