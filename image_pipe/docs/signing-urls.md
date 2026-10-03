# Signing URLs and rotating keys

Require signed URLs, so the server serves only the URLs your application
generated, and replace the signing key later without breaking URLs in use.
This assumes ImagePipe running in your app or as `image_pipe_server`, with
URLs built by `ImagePipe.URL`. [Signing and source concealment](urls.md)
explains what a signature covers.

## Generate a key

A signing key is a hex string. Generate 32 random bytes:

```sh
openssl rand -hex 32
```

Store the result as a secret, for example in an environment variable named
`IMAGE_PIPE_SIGNING_KEY`. Keep the key on your servers.

## Configure the server

<!-- tabs-open -->

### image_pipe_server

Pass the key in `IPS_URL__KEYS`, or in a file named by `IPS_URL__KEYS_FILE`
for Docker and Kubernetes secrets:

```sh
IPS_URL__KEYS=0123abcd…
```

The server reads it at startup. See
[`[url]`](../../image_pipe_server/docs/server-configuration.md#url).

### Plug

Give the instance a URL configuration with the key:

```elixir
# lib/my_app/application.ex
{ImagePipe,
 name: MyApp.Images,
 url:
   ImagePipe.URL.config(
     base_url: "/images",
     keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
   ),
 sources: [...]}
```

<!-- tabs-close -->

From now on, the server answers unsigned URLs with `403` and the body
`invalid signature`.

## Sign URLs in the builder

In an app that serves its own URLs, build them from the instance's URL
configuration, which already has the key:

```elixir
url_config = ImagePipe.url_config(ImagePipe.config!(MyApp.Images))
```

An application that builds URLs for a separate server uses the same key:

```elixir
url_config =
  ImagePipe.URL.config(
    base_url: "https://img.example.com/images",
    keys: [System.fetch_env!("IMAGE_PIPE_SIGNING_KEY")]
  )
```

Every URL generated from `url_config` is signed. With the second
configuration:

```elixir
thumbnail = ImagePipe.URL.new(url_config) |> ImagePipe.URL.group(resize: [width: 400])

ImagePipe.URL.url!(thumbnail, "photos/beach.jpg")
# "https://img.example.com/images/sig=Sr0wHrHp…/w=400/src/photos%2Fbeach.jpg"
```

Generate URLs in server code, such as a controller or template, and send the
browser only the finished URL. Assign `thumbnail` to the template, then:

```heex
<img src={ImagePipe.URL.url!(@thumbnail, @photo.source)} />
```

To sign a path you built yourself, pass it to `ImagePipe.URL.sign_path/2`
and prepend the base URL yourself:
`"https://img.example.com/images" <> ImagePipe.URL.sign_path("/w=400/src/photos/beach.jpg", url_config)`.

## Add an expiry

To make a URL stop working at a given time, pass `expires` as a Unix time in
seconds:

```elixir
ImagePipe.URL.new(url_config, expires: System.os_time(:second) + 3600)
```

After that second, the URL answers `410` with the body `expired`. A new
expiry gives a new URL, which browsers and CDNs can't serve from their
cache. To keep one URL per image for a while, round the expiry up, for
example to the end of the day.

## Check that signing works

Request a generated URL, then the same URL with one option changed:

```sh
curl -s -o /dev/null -w "%{http_code}\n" "https://img.example.com/images/sig=Sr0wHrHp…/w=400/src/photos%2Fbeach.jpg"
# 200
curl -s -w "\n%{http_code}\n" "https://img.example.com/images/sig=Sr0wHrHp…/w=800/src/photos%2Fbeach.jpg"
# invalid signature
# 403
```

## Rotate the key

During the switch, both lists hold the old and the new key:

1. Generate a new key.
2. Add the new key to the server's list, after the current one, and restart
   the server: `IPS_URL__KEYS=<old>,<new>` for `image_pipe_server`, or
   `keys: [old, new]` for the Plug. The server now accepts both keys.
3. Put the new key first in the builder's list and keep the old key second:
   `keys: [new, old]`. New URLs are signed with the new key.
4. Wait until nothing requests URLs signed with the old key: after the
   longest `expires` you gave out, and after pages and caches holding those
   URLs have been refreshed. A URL without `expires` stays valid as long as
   the server has its key.
5. Remove the old key from both lists.

In an app that serves its own URLs, the server and the builder share one
list, so steps 2 and 3 are one change to `keys: [new, old]`. When several
nodes run the app, deploy `keys: [old, new]` to every node first, then
`keys: [new, old]`, so no node signs with a key another node doesn't accept
yet.

To see which key verified a request, read `:sig_key_index` from the
`[:image_pipe, :parse]` stop event (see [telemetry events](telemetry-events.md)).
It is `1` for a URL signed with the key second in the list.

## Next steps

- [Shared URL settings](shared-url-settings.md): everything else the server
  and an external builder must agree on.
- [Source concealment](urls.md#source-concealment): hide the image's path
  in the URL as well.
- [Serving images through a CDN](serving-through-a-cdn.md): cache lifetimes
  for URLs with an expiry.
