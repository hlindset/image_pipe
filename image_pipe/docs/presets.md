# Presets

A preset is a named set of URL options defined in the server's
configuration, such as `card` for `w=400/h=300/fit=cover`. URLs carry only
the name, `preset=card`, so changing the definition changes the image every
`preset=card` URL serves, without generating new URLs.

- [Defining presets](defining-presets.md): adding presets and request
  defaults to `image_pipe_server` or the Plug.
- [Storing presets in a database](storing-presets-in-a-database.md): loading
  definitions while serving a request.
- [Named presets](requesting-images.md#named-presets): using presets in a
  URL.

## Presets and existing URLs

The signature of a signed URL covers the preset's name, not its definition,
so a changed definition keeps every URL valid. The server caches the
processed image by the options a preset expands to. `/preset=card` and
`/w=400/h=300/fit=cover` share one cached copy and one ETag, and changing
`card` changes the cache key of every request that uses it, so those images
are processed again.

Removing a definition breaks its URLs, which then answer `400` with
`unknown preset`. A preset defined as an empty string adds no options, so it
retires a name while keeping its URLs working: `/preset=old/w=600` then
serves the same image as `/w=600`. Decide this per preset. URLs that relied
on a preset to add a watermark, crop out part of the image, or cap the size
would quietly lose it.

## Request defaults

The server's configuration can also set request defaults: one group of
options, such as `q=80`, applied to every request. They apply to the first
group, under any presets and options the URL writes there. Request defaults
never appear in URLs and can't name presets.

## Precedence within a group

Within one group, three layers combine, each overriding the one before it:

1. The request defaults, in the first group only.
2. Presets, in the order the URL lists them. In `preset=card,dark`, `dark`
   wins where both set an option.
3. Options written in the URL.

An option written in the URL overrides presets only in its own group, so
`/w=300/-/preset=card` resizes twice. Presets in separate groups stack, so
`/preset=frame/-/preset=frame` pads twice.

Some options override a related set of options rather than one value, so a
URL can't end up with a half-inherited setting. Writing `focus` in a URL
replaces the preset's whole crop target, including an `anchor` and its
offset. [Named presets](requesting-images.md#named-presets) lists these
sets.

## Clearing inherited values

`unset` removes a value that a preset or the request defaults set, as if no
layer had set it, and takes the options that depended on it along.
`/preset=card/w=unset` drops the width, and the inherited `fit` and
`enlarge` go too unless `h` still uses them. Options written in the same URL are kept, so `/preset=card/w=unset/fit=cover`
still fails when nothing else resizes. Because `unset` has this meaning, no
watermark or detection class can be named `unset`.

## Request-wide options in presets

Some options, such as `format` and `q`, apply to the whole request rather
than to one group. A preset's request-wide options apply to the whole
request, whichever group the preset is written in. When presets in different
groups set the same request-wide option, the later one in the URL wins, and an
option written in the URL wins over every preset. A group whose presets add
only request-wide options adds no group: with `webp` defined as
`format=webp`, `/w=800/-/preset=webp` is the same request as
`/w=800/format=webp`.

## Single-group and pipeline presets

A preset without `-` is a single-group preset. It works like an ingredient:
a set of options you could have written yourself, applied to the group it is
written in. In `/w=800/-/trim=auto/preset=frame`, `frame` pads the image
after the trim, in the second group.

A preset containing `-` is a pipeline preset: a complete recipe that
supplies every group of the request. Building recipes from ingredients keeps
the ingredients available for requests that need something slightly
different:

```text
card   = w=400/h=300/fit=cover
frame  = pad=20/bg=fff
framed = preset=card/-/preset=frame/format=webp
```

A preset named inside another preset applies to the group it is written in,
so `frame` pads the second group of `framed`. Request-wide options can still
come from anywhere: `/preset=framed/format=png` and `/preset=framed,webp`
both work. Any other option or preset added to a pipeline preset is
rejected, because no rule says which of the recipe's groups it would join.

### Pipeline preset errors

With `framed` defined as above, these requests answer `400` with the
message in the response body:

| Request | Message |
| --- | --- |
| `/preset=framed/w=500` | `pipeline preset "framed" cannot be combined with group options` |
| `/w=800/-/preset=framed` | the same |
| `/preset=framed/-/sharpen=1` | the same |
| `/preset=framed,card` | `pipeline preset "framed" cannot be combined with preset "card", which sets group options` |
| `/preset=framed/-/preset=card` | the same |
| `/preset=framed,other`, both pipeline presets | `pipeline presets "framed" and "other" cannot be combined` |

The URL builder returns the same errors as `ImagePipe.Plan.Spec.Issue`
reasons.

The same rules apply inside preset definitions. A definition that breaks
them stops the server at startup, or answers `500` when it comes from a
preset lookup.

## Stored presets

A server can also load presets from a database or another service while it
serves a request, through a preset lookup in an Elixir application. Stored
presets follow the same rules as presets in the configuration, with three
differences:

- A name defined in the configuration always wins, and the lookup is never
  asked for it.
- A stored preset may name presets from the configuration, but a preset in
  the configuration can't name a stored one.
- Errors in a stored definition show up when a request uses it, as `500`,
  rather than at startup.

[Storing presets in a database](storing-presets-in-a-database.md) sets one
up.
