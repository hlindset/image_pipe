# Source network policy

An HTTP source downloads from addresses that an image URL can name. Without
limits, a request such as `src/http://169.254.169.254/latest/meta-data/`
would make ImagePipe fetch from inside your network and hand back what it
finds. This is server-side request forgery (SSRF). The HTTP source prevents
it with two checks on every download: the host must be one you listed, and
the address it connects to must be on the public internet.

## Hosts and addresses

`allowed_hosts` is the first check. A source accepts URLs only for the
hosts you list, or the host and port of its `base_url`, so a request can't
name an arbitrary server. Each entry allows only the default port, 80 for
`http` and 443 for `https`, unless the entry names a port, as in
`assets.example.com:8443`. So a request can't reach another service on an
allowed host by picking its port.

A hostname is not enough on its own, because DNS decides where it points.
`assets.example.com` could resolve to `10.0.0.5` through a misconfigured
record, or through an attacker who controls the domain's DNS. So the source
also resolves the host and refuses the download unless every address it
gets back is public. A mix of public and private addresses is refused too,
since any of them might be the one used.

Addresses that aren't public include loopback (`127.0.0.1`), private
ranges (`10.0.0.0/8` and the other RFC 1918 ranges), link-local addresses
such as the cloud metadata service at `169.254.169.254`, carrier-grade NAT,
multicast, and reserved ranges. The full list is in
[address policy](`m:ImagePipe.Source.HTTP#module-address-policy`).

An address written in an unusual form is checked as the address it means.
`2130706433`, `0x7f.1`, and `127.1` are all `127.0.0.1`, and an IPv6
address that embeds an IPv4 address, such as `::ffff:10.0.0.5`, is checked
as `10.0.0.5`. NAT64 addresses are treated as non-public.

## Connecting to the checked address

Checking the address and then letting the HTTP client resolve the host again
would leave a gap: DNS can answer differently the second time. This is
called DNS rebinding. Instead, the source connects to the address it
checked, while still sending the hostname in the `Host` header and verifying
the TLS certificate against it. The origin sees an ordinary request.

Connections are pooled per hostname and address, so a connection opened to
one address is never reused after the host resolves somewhere else, and a
forward proxy is asked for the checked address too.

## Redirects

A redirect is a new download and gets the same checks: its host must be
listed, and its addresses must be public. Redirects aren't followed at all
unless the source sets `max_redirects`.

## Private origins

Some origins are meant to be private, such as an image store on your own
network. You can allow specific address ranges, or whole categories such as
private addresses, for one source (see
[allow a private origin](serving-from-http.md#allow-a-private-origin)).
Allowing a narrow range keeps the protection for everything else on that
network, so prefer `10.0.5.0/24` for an origin over all private addresses.

Denied downloads answer `404 source not found`, the same as a missing
image. A client can't use the answer to learn which hosts or addresses
exist behind the server (see [error responses](errors.md)).
