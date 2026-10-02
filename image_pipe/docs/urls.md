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
url_config = ImagePipe.URL.config(base_url: "/images")
plan = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 400])
url = ImagePipe.URL.url!(plan, "https://assets.example.com/cat%23one.jpg")
```

The mount must configure the corresponding [source adapter](sources.md).
The builder takes the original source string; never pass a source marker or
pre-encode the entire string. Source filename extensions do not set output format.

## Presets

Define recipes on the serving configuration. URLs carry only their names:

```elixir
config = ImagePipe.config(
  request_defaults: "q=80",
  presets: %{
    "card" => "w=400/h=300/fit=cover",
    "framed" => "preset=card/-/pad=20/bg=fff/format=webp"
  },
  sources: [
    media: [
      adapter: ImagePipe.Source.File,
      match: :path,
      options: [root: "/srv/images", root_id: "media"]
    ]
  ]
)
mount = ImagePipe.Plug.init(config: config)
poster = ImagePipe.URL.new(ImagePipe.url_config(config)) |> ImagePipe.URL.group(presets: ["card"])
url = ImagePipe.URL.url!(poster, "photos/beach.jpg")
```

```text
/preset=card/w=600/src/photos/beach.jpg
/preset=framed/format=png/src/photos/beach.jpg
```

Preset names contain letters, digits, dots, underscores, and hyphens. Nested
references compile at initialization; unknown names and cycles fail there.
A preset may be an empty string, which contributes nothing: use it to retire
a name without breaking its URLs.

Presets and request defaults accept an `ImagePipe.URL` builder in place of a
string. It compiles exactly like its URL spelling:

```elixir
presets: %{
  "card" => ImagePipe.URL.new() |> ImagePipe.URL.group(resize: [width: 400, height: 300, fit: :cover])
}
```

`request_defaults` apply to the first group of every request, before its
presets and explicit options. They are one group, cannot select presets, and
never appear in URLs. Sources and signatures cannot appear in presets.

### Single-group presets and pipeline presets

A preset without `-` is a single-group preset. Think of it as an ingredient: a
bundle of options you could have written yourself. It applies to the group it
is written in, wherever it appears within that group:

```text
/w=800/-/trim=auto/preset=frame/src/photos/beach.jpg
```

Here `frame` pads the image after the trim, in the second group. Within a
group, multiple names use `preset=first,second`; later presets take
precedence, then the group's explicit options. An explicit option overrides
presets only in its own group, so `/w=300/-/preset=card` resizes twice.
Presets in separate groups stack: `/preset=frame/-/preset=frame` pads twice.

A preset's request options, such as `format` or `q`, apply to the whole
request whichever group it is written in. When presets in different groups set
the same request option, the later one in the URL wins. Explicit request
options win over every preset. A group whose presets add only request options
adds no group: `/w=800/-/preset=webp` with `webp = format=webp` is the same
request as `/w=800/format=webp`.

A preset containing `-` is a pipeline preset: a recipe that supplies the
complete group sequence. Build recipes from ingredients, so a request that
needs something slightly different can assemble the ingredients itself:

```elixir
presets: %{
  "card" => "w=400/h=300/fit=cover",
  "frame" => "pad=20/bg=fff",
  "framed" => "preset=card/-/preset=frame/format=webp"
}
```

Nested references apply to the group they are written in, so `frame` pads
framed's second group. A pipeline preset must supply every group option in
the request. Request options may still come from anywhere, so
`/preset=framed/format=png` works. These combinations are rejected with `400`,
because which of the recipe's groups the other options would join is
undefined:

| Request | Reason |
| --- | --- |
| `/preset=framed/w=500` | `pipeline_preset_with_group_options`: explicit group options in the recipe's group |
| `/w=800/-/preset=framed` | `pipeline_preset_with_group_options`: group options in another group |
| `/preset=framed/-/sharpen=1` | `pipeline_preset_with_group_options`: same |
| `/preset=framed,card` | `pipeline_preset_with_preset`: another preset sets group options |
| `/preset=framed/-/preset=card` | `pipeline_preset_with_preset`: same |
| `/preset=framed,other` (both pipelines) | `multiple_pipeline_presets` |

A preset that sets only request options combines with a pipeline preset:
`/preset=framed,webp` works. The same rules apply inside preset definitions,
which fail at initialization (or with `500` when looked up) if they break them.

Related alternatives replace one another: `anchor`/`focus`/`detect` replace the
inherited guide and its offset; `region` replaces inherited `crop` and ratio
settings; `wm`/`wm-src64`/`wm-enc` replace the inherited watermark asset; `q`
and `autoquality` form an override family. Canvas mode, placement,
and offset are another family, so supply the intended canvas settings together.
`extend=false` or `extend-ratio=false` disables inherited canvas settings.

To remove a value a preset or the request defaults set, write `unset`. Every
option except `preset` accepts it, and the request then behaves as if no layer
had set the option:

| Request | Effect |
| --- | --- |
| `/preset=brand/wm=unset` | no watermark, and no inherited `wm-opacity`, `wm-at`, or other placement |
| `/format=unset` | negotiate the format from `Accept` again |
| `/q=unset`, `/meta=unset`, `/jpeg-options=unset` | use the host configuration |
| `/preset=card/w=unset` | drop the width; inherited `fit`, `enlarge`, and the guide go too unless `h` or a crop still uses them |

Options written in the same URL are kept, so `/preset=card/w=unset/fit=cover`
still fails when nothing else resizes. `unset` is reserved: a watermark asset or
detection class can't be named `unset`.

Presets share cache identity with equivalent explicit requests. Plug and direct
Elixir execution expand presets using the same rules. URL generation preserves
named references so changing their definitions leaves URLs stable.

### Validating URLs before serving

The URL builder checks a plan's combined options only when it knows the
mount's presets. `ImagePipe.url_config(config)` returns the configuration's URL
settings with that knowledge filled in. A URL configuration from
`ImagePipe.URL.config/1` alone checks values only, so `url/3` and `validate/1`
accept plans that the mount may still reject with `400`.

When the builder runs in another application, describe the mount with
`:mount_presets`, typically from a shared configuration value:

```elixir
ImagePipe.URL.config(
  keys: keys,
  mount_presets: [presets: shared_presets, request_defaults: "q=80", preset_lookup: true]
)
```

`preset_lookup: true` says that the mount has a lookup, so names the map lacks
are left to the mount. The copy only affects validation; a stale one gives
wrong results but never changes a URL. `ImagePipe.validate(config, builder)`
runs the full check, including the lookup, in the serving application.

### Preset lookup

To keep presets in a database or cache server, implement
`ImagePipe.PresetLookup` and pass it as `:preset_lookup`. It resolves names
the static `:presets` map does not define, while the mount parses a request:

```elixir
defmodule MyApp.Presets do
  @behaviour ImagePipe.PresetLookup

  import Ecto.Query

  @impl true
  def validate_options(options), do: {:ok, options}

  @impl true
  def fetch(names, options) do
    repo = Keyword.fetch!(options, :repo)
    query = from p in "presets", where: p.name in ^names, select: {p.name, p.fragment}
    {:ok, Map.new(repo.all(query))}
  end
end

config = ImagePipe.config(
  presets: %{"card" => "w=400/h=300/fit=cover"},
  preset_lookup: {MyApp.Presets, repo: MyApp.Repo},
  sources: [...]
)
```

`fetch/2` receives a batch of names and returns the fragments it knows; omit
the rest. It runs once per nesting level, so a request without nested lookups
makes one call. Static names shadow the lookup and are never fetched, and
requests that use only static presets never call it. Looked-up presets may
reference static ones, but static presets may reference only static names.
`request_defaults` never involve the lookup.

- An unknown name answers `400`. A lookup that returns `{:error, _}`, raises,
  exits, or returns a malformed value answers `503`. A stored fragment that
  fails to parse, references an unknown preset, or forms a cycle answers `500`.
  All of these return before source fetch or cache access.
- `:max_preset_lookups` (default `32`) caps the distinct names one request may
  look up; exceeding it answers `500`.
- To retire a stored preset, return `""` for it rather than omitting it, so its
  URLs keep working. Decide per preset: one that carries a watermark, a
  concealing crop, or a size cap should not quietly become empty.
- ImagePipe does not cache lookups. Cache in your implementation, for example
  in ETS or Cachex, and bound backend timeouts in your client configuration.
- Changing a stored definition changes the cache key and ETag of the requests
  that use it.
- URL generation never calls the lookup.

## Signing and expiry

Configure the same signing keys in the URL builder and mount:

```elixir
url_config = ImagePipe.URL.config(
  base_url: "/images",
  keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
)

plan =
  ImagePipe.URL.new(url_config, expires: System.os_time(:second) + 3600)
  |> ImagePipe.URL.group(resize: [width: 400])

url = ImagePipe.URL.url!(plan, "photos/beach.jpg")
mount = ImagePipe.Plug.init(url: url_config, sources: sources)
```

Keys are hex strings. Generate a key once, for example with
`Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)`, and store it in
server-side configuration. With keys configured, the mount requires a
`sig=<mac>` prefix that authenticates the complete mount-relative path after
the signature. The router prefix and hostname are outside the signature.
Without keys, unsigned requests are accepted.

To sign an existing path without the builder, use the same URL configuration:

```elixir
path = "/w=400/src/photos/beach.jpg"
url = "/images" <> ImagePipe.URL.sign_path(path, url_config)
```

`sign_path/2` returns `/sig=<signature>` followed by the exact supplied path.
It requires signing keys and a leading `/`, and rejects an existing signature
prefix, query string, or fragment. Escape source query parameters into the path
before signing. It preserves existing escaping and does not parse processing
options or encrypt sources. Prepend the hostname and mount prefix yourself;
the helper does not apply `:base_url`.

The first key signs new URLs; keep previous keys in the list while their URLs
remain valid. `expires` is a Unix timestamp in seconds. The exact expiry second
is still valid; later requests return 410 before source/cache access. Expiry
should be signed so clients cannot extend it.

## Conceal the source

Add `encrypt_source: true` and independent `source_encryption_keys` to the URL
configuration. Signing keys use hex strings; encryption keys use raw 32-byte
binaries. The builder emits a signed `enc/<token>` path.

Deterministic IV generation preserves URL stability for identical source/key
pairs. Use `iv_mode: :random` or a per-call `iv: :random` for randomized tokens.
Encryption hides source contents but reveals padded length; deterministic
tokens also reveal equality. Generate URLs on the server and expose only the
completed URL. See [encrypted sources](elixir-api.md#encrypted-sources) for a
complete example and key rotation, and the [concealment contract](api_contract.md#source-concealment)
for cryptographic details.
