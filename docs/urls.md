# URLs and presets

An ImagePipe path contains processing options followed by a source marker and
identifier. A mount prefix belongs to your router:

```text
/images/w=400/h=300/fit=cover/format=webp/src/photos/beach.jpg
└ mount ┘└──────────── options ────────────┘└──── source ────┘
```

Options use `name=value` segments. Boolean flags such as `enlarge` can be bare;
use `enlarge=false` to explicitly disable one. Duplicate, conflicting, unknown,
or inapplicable options are rejected. Option values do not support percent
escapes. See the [processing index](processing.md) for accepted values.

## Groups and ordering

Options within a group run in a fixed order, regardless of where they appear
in the path. Use `-` to begin another processing pass:

```text
/w=500/-/trim=fff/src/photos/beach.jpg
```

That resizes before trimming. `/w=500/trim=fff/src/photos/beach.jpg` trims before
resizing. Group settings reset at `-`; request-wide output and delivery
settings apply to the final result. See [processing order](processing.md#processing-order).

## Source encoding

| Marker | Representation |
| --- | --- |
| `src` | Source tail percent-decoded once |
| `src64` | Unpadded base64url source bytes |
| `enc` | Authenticated encrypted source token |

For a source URL containing `cat%23one.jpg`, the outer `src` form needs
`cat%2523one.jpg`. Generate URLs instead of hand-escaping them:

```elixir
config = ImagePipe.config(base_url: "/images")
plan = ImagePipe.new(config) |> ImagePipe.group(resize: [width: 400])
url = ImagePipe.url!(plan, "https://assets.example.com/cat%23one.jpg")
```

The mount must configure the corresponding [source adapter](sources.md).
The builder takes the original source string; never pass a source marker or
pre-encode the entire string. Source filename extensions do not set output format.

## Presets

Define URL recipes on the Plug mount:

```elixir
mount = ImagePipe.Plug.init(
  sources: [path: {ImagePipe.Source.File, root: "/srv/images", root_id: "media"}],
  presets: %{
    "card" => "w=400/h=300/fit=cover",
    "framed" => "preset=card/-/pad=20/bg=fff/format=webp"
  }
)
```

```text
/preset=card/w=600/src/photos/beach.jpg
/preset=framed/format=png/src/photos/beach.jpg
```

Preset names contain letters, digits, dots, underscores, and hyphens. Nested
references compile at initialization; unknown names and cycles fail there.
A preset named `default` applies automatically. Multiple names use
`preset=first,second`; later presets take precedence, then explicit URL options.

Single-group presets contribute to the first group. A pipeline preset containing
`-` supplies the complete sequence; it accepts request-wide overrides such
as `format=png`, but cannot combine with explicit group options or another
pipeline preset. Sources and signatures cannot appear in presets.

Related alternatives replace one another: `anchor`/`focus`/`detect` replace the
inherited guide and its offset; `region` replaces inherited `crop` and ratio
settings; `q` and `autoquality` form an override family. Canvas mode, placement,
and offset are another family, so supply the intended canvas settings together.
`extend=false` or `extend-ratio=false` disables inherited canvas settings.

Presets share cache identity with equivalent explicit requests. Elixir plans
do not expand mount presets; use reusable plan-building functions for
[combined usage](combined-usage.md).

## Signing and expiry

Configure the same signing keys in the URL builder and mount:

```elixir
config = ImagePipe.config(
  base_url: "/images",
  keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
)

plan =
  ImagePipe.new(config, expires: System.os_time(:second) + 3600)
  |> ImagePipe.group(resize: [width: 400])

url = ImagePipe.url!(plan, "photos/beach.jpg")
mount = ImagePipe.Plug.init(config: config)
```

Keys are hex strings. Generate a key once, for example with
`Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)`, and store it in
server-side configuration. With keys configured, the mount requires a
`sig=<mac>` prefix that authenticates the complete mount-relative path after
the signature. The router prefix and hostname are outside the signature.
Without keys, unsigned requests are accepted.

To sign an existing path without the builder, use the same shared config:

```elixir
path = "/w=400/src/photos/beach.jpg"
url = "/images" <> ImagePipe.sign_path(path, config)
```

`sign_path/2` returns `/sig=<signature>` followed by the exact supplied path.
It requires signing keys and a leading `/`, and rejects an existing signature
prefix, query string, or fragment. Escape source query parameters into the path
before signing. It preserves existing escaping and does not parse processing
options or encrypt sources. Prepend the hostname and mount prefix yourself;
the helper does not apply `:base_url`.

The first key signs new URLs; keep previous keys in the list while their URLs
remain valid. `expires` is a Unix timestamp in seconds. The exact expiry second
is still valid; later requests return 404 before source/cache access. Expiry
should be signed so clients cannot extend it.

## Conceal the source

Add `encrypt_source: true` and independent `source_encryption_keys` to shared
configuration. Signing keys use hex strings; encryption keys use raw 32-byte
binaries. The builder emits a signed `enc/<token>` path.

Deterministic IV generation preserves URL stability for identical source/key
pairs. Use `iv_mode: :random` or a per-call `iv: :random` for randomized tokens.
Encryption hides source contents but reveals padded length; deterministic
tokens also reveal equality. Generate URLs on the server and expose only the
completed URL. See [encrypted sources](elixir-api.md#encrypted-sources) for a
complete example and key rotation, and the [concealment contract](api_contract.md#source-concealment)
for cryptographic details.
