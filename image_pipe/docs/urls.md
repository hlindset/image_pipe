# Signing and source concealment

A signed URL proves that your application generated it, so the server
rejects any URL a client edited or made up. A concealed source goes further
and hides which image the URL points at. Both are optional, and both work the
same for `image_pipe_server` and `ImagePipe.Plug`.

- [Signing URLs and rotating keys](signing-urls.md): turning on signing and
  replacing a key.
- [Shared URL settings](shared-url-settings.md): the keys and other
  settings the server and the URL builder must agree on.
- [Signed URLs](requesting-images.md#signed-urls): what a signed URL looks
  like to the people who request images.

## Purpose of signing

Without signing, anyone who can reach the server can request any size, crop,
or effect of any image the server can read. Each new combination is a new
image to fetch, process, and store in the cache. With signing keys
configured, the server serves only the URLs your application generated, and
answers every other request with `403` before it fetches the source or reads
the cache.

## What a signature covers

```text
https://img.example.com/images/sig=<signature>/w=400/expires=1767225600/src/photos/beach.jpg
```

The signature is an HMAC-SHA256 of everything after the `sig=` segment: the
options, the expiry, and the image path, byte for byte. Changing any of them
gives `403` with the body `invalid signature`.

The hostname and the path the server is mounted at (`/images` here) are
outside the signature. A URL signed for your CDN's address is also valid at
the server's internal address, and moving the server to another path needs
no new signatures.

The signature covers a preset's name, not its definition. When the server's
`card` preset changes from 400 to 480 pixels wide, every signed
`preset=card` URL stays valid and serves the wider image.

## Expiry

A signed URL can carry an `expires` time, in Unix seconds. The server accepts
the URL up to and including that second and answers `410` with the body
`expired` after it, before fetching the source. The expiry is inside the
signed part of the URL, so a client can't extend it. Without signing keys,
the server still checks `expires`, but anyone can edit it.

An expiry is part of the URL, so a URL generated with a new expiry on every
page view is a new URL every time, and browsers and CDNs can't reuse their
cached copy.

## Signing keys

A signing key is a secret, written as hex. The server and the URL builder
each hold a list of keys. The builder signs with the first key in its list,
and the server accepts a signature made with any key in its list.

The list is what makes it possible to replace a key without breaking URLs
already in use: the server accepts the old and the new key while URLs signed
with either are still requested. [Signing URLs and rotating keys](signing-urls.md#rotate-the-key)
gives the steps.

Anyone holding a key can sign any URL, which is why URLs are generated in
server code and the browser receives only the finished URL.

## Source concealment

A concealed source replaces `src/photos/beach.jpg` with an encrypted token:

```text
/images/sig=XzyslPgT…/w=400/enc/Aa_ELvrY…
```

The token hides the whole source, including a private hostname, the path,
and credentials in its query string. Watermark sources in the same URL are
encrypted too. The token is encrypted with source encryption keys, which are
separate from the signing keys, and concealed URLs are always signed.
[Shared URL settings](shared-url-settings.md#source-encryption-keys)
shows how to configure the keys on both sides.

### Deterministic and random tokens

By default, the same source and encryption key always give the same token,
whatever the processing options, and in any process. A URL for `beach.jpg` at
`w=400` and one at `w=400/-/blur=2` carry the same `enc/` token.
Generating the same URL again gives the same string, so browsers and CDNs
keep reusing their cached copy.

In random mode (the URL builder's `iv_mode` option, see
[source encryption keys](shared-url-settings.md#source-encryption-keys)),
each URL gets a new token. Random tokens hide that two URLs show the same
image, at the cost of a new URL each time for browsers and CDNs. The server
caches the processed image by its decrypted source, so both modes share the
server's stored copies and ETags with each other and with the same source
written as `src/`.

### What a token reveals

- A token's length shows the source's length to within 16 bytes.
- Deterministic tokens show which URLs have the same source.

The token protects the source only while nobody else can encrypt with your
keys, so no endpoint may encrypt any source it's given. With such an
endpoint, someone can encrypt a guessed source and compare the token with a
URL they've seen.

The [concealment contract](api_contract.md#source-concealment) specifies the
encryption, key derivation, and token format.
