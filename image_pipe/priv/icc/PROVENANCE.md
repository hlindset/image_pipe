# ICC profile provenance

These three **CC0 / public-domain profiles** provide the API's `profile=srgb`,
`profile=display-p3`, and `profile=adobe-rgb` output targets. Each profile uses
the named color space's primaries. Its embedded description and
tone-response-curve representation come from the source collection below.

All three files are taken verbatim from
[saucecontrol/Compact-ICC-Profiles](https://github.com/saucecontrol/Compact-ICC-Profiles),
which releases every profile in the collection under
[CC0 1.0 Universal](https://github.com/saucecontrol/Compact-ICC-Profiles/blob/master/license)
(public domain). They are small ICC v4 matrix profiles (480 bytes each).

| File | Target atom | Source / generation + license | SHA-256 |
|------|-------------|-------------------------------|---------|
| `sRGB.icc` | `:srgb` | `sRGB-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/sRGB-v4.icc) — CC0 1.0. sRGB primaries, D65. | `c56e1685d888f5edb92fe07f2750f387f8fe8e91b32ff8fb0b56bfbbb9458353` |
| `DisplayP3.icc` | `:display_p3` | `DisplayP3-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/DisplayP3-v4.icc) — CC0 1.0. Display-P3 (DCI-P3) primaries, D65 white, sRGB TRC. | `cb51de38e482ee974c0c76b9689e16aad04bad16e226fed2f30c842d15ff3a3d` |
| `AdobeRGB.icc` | `:adobe_rgb` | `AdobeCompat-v4.icc` from [saucecontrol/Compact-ICC-Profiles](https://raw.githubusercontent.com/saucecontrol/Compact-ICC-Profiles/master/profiles/AdobeCompat-v4.icc) — CC0 1.0. Adobe RGB 1998 primaries, D65, gamma ~2.2. | `1e35b53d118eba6835a7bac06137ea87cd5ad6eee97b20a88b29ab6356b00e43` |

Verify integrity with:

```sh
shasum -a 256 priv/icc/*.icc
```
