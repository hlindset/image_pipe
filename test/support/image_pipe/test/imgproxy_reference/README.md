# Imgproxy pixel references

These three PNGs are immutable reference outputs baked by upstream imgproxy.
The tests send equivalent requests through ImagePipe's native URL API; no
imgproxy parser or runtime code participates.

The original fixture manifest recorded these generator fields verbatim:

- `imgproxy_digest`: `sha256:9ed8f87b34d55c7844951ff65bcf6605de54ba6670f64951c7215f9b125a482e`
- `imgproxy_libvips`: `42.20.2`
- `pipe_libvips_at_gen`: `8.18.2`

Each comparison preserves the differential suite's default tolerance: at most
64 band samples may differ by more than 2 levels. The source and fixture hashes
below are part of the provenance. Do not regenerate a fixture to accommodate an
ImagePipe change.

| Fixture | Source SHA-256 | Fixture SHA-256 | Imgproxy options | Native options |
| --- | --- | --- | --- | --- |
| `crop_gravity_placement.png` | `eb3de4dce6337ed2bd531b35187bcda3265542dc5b661152631839616eca7d09` | `65c19f17fcf0110fa45ef5e46a77e3ca9d90f1f4f017f229019d3b16aa089ff3` | `c:120:90/g:nowe` | `crop=120,90/anchor=top-left` |
| `effects_chain_order_high_freq.png` | `54ded6c57ec02c685e275276b54947f8c9345015342fc8a2acc9d8e54e4a7d43` | `6dabd60fea767033d02075a8815bdabf88f716dbbe1cb3630a108c654e14a203` | `rs:fit:240:240/bl:2/sh:2/pix:8` | `w=240/h=240/fit=contain/blur=2/sharpen=2/pixelate=8` |
| `trim_equal_hv_border.png` | `9782adfcd78b6033d6d97797bf76709fca200d5789491e4e8f080541e17b7ebd` | `e00a29a6c06e316258b52fb51795248503b7d2c25d48676bca3615b9d0e96bfc` | `t:10::1:1` | `trim=auto/trim-symmetry=hv` |
