# ImagePipe SVG

SVG support for [ImagePipe](https://hex.pm/packages/image_pipe). With this
package installed, ImagePipe renders SVG originals and SVG watermarks with
[resvg](https://github.com/linebender/resvg), straight at the size each
request needs. It ships a precompiled native library, so installing it needs
no Rust toolchain.

```elixir
{:image_pipe_svg, "~> 0.1"}
```

ImagePipe calls this package itself. Its configuration, fonts, and limits are
covered in
[Serving SVG images](https://hexdocs.pm/image_pipe/serving-svg-images.html).
