# Source network policy (SSRF protection)

`ImagePipe.Source.HTTP` validates every origin and redirect destination before
connecting. By default it connects only to public addresses.

## Default policy

For each request, and again for each redirect, the adapter:

1. Requires an `http`/`https` scheme.
2. Requires the (case-insensitive) host to be in `allowed_hosts` — redirects may
   not leave the allowlist.
3. Resolves the host and **denies the fetch if any resolved address is not
   public** (loopback, unspecified, link-local, private, CGNAT, unique-local,
   multicast, broadcast, or otherwise reserved).
4. Connects directly to a validated IP, preserving the original HTTP Host,
   TLS server name and certificate hostname verification. A failed connection
   may try the next validated address; HTTP responses and body failures do not
   trigger address failover.

Each redirect is resolved, validated and pinned separately. Connection pools
are separated by the logical hostname and selected address, so a previously
opened connection cannot bypass a new address decision. The logical URL is
retained for request signing, redirect resolution and origin cache validators.
With a configured forward proxy, plain HTTP request targets use the validated
IP and HTTPS CONNECT targets use that IP; the origin hostname is retained for
HTTP Host and TLS identity.

IPv4 literal encodings (decimal, octal, hex) and IPv4-mapped / NAT64 / 6to4 IPv6
forms are canonicalized before classification, so they cannot be used to smuggle
an internal address past the check.

A denied fetch returns `{:error, {:source, reason}}`, where `reason` is
`:denied_scheme`, `:denied_host`, or `:denied_address`. Fetching opens the remote
response through its headers; the body is consumed lazily. Use
`ImagePipe.Source.with_fetched/3` to release the response even when its body is
not consumed, or close a directly fetched response with
`ImagePipe.Source.Response.close/1`.

## Allowing private origins

Set `address_policy` on the source adapter. It accepts either a keyword list or a
function.

### Keyword list

```elixir
sources: [
  url: {ImagePipe.Source.HTTP,
    allowed_hosts: ["assets.internal"],
    address_policy: [
      allow_private: true,         # opens ALL RFC1918 ranges
      allow: ["10.0.5.0/24"]       # OR open exactly one range, precisely
    ]
  }
]
```

Toggles: `allow_loopback`, `allow_unspecified`, `allow_link_local`,
`allow_private`, `allow_unique_local`, `allow_multicast`, `allow_broadcast`,
`allow_cgnat`, `allow_reserved`. `allow:` is a list of CIDR strings. Omitting
`address_policy` denies everything that is not public.

### Function

```elixir
address_policy: fn _ip, category -> category == :public end
```

The function receives the canonicalized IP tuple and its category and returns a
boolean. It replaces the built-in decision. A non-boolean return or a raised
exception is treated as **deny** (fail-closed).

## Custom DNS resolution

`address_resolver` overrides how hostnames resolve, e.g. a caching resolver:

```elixir
address_resolver: fn host -> {:ok, [{93, 184, 216, 34}]} end
```

It returns `{:ok, [ip_tuple]}` or `{:error, term}`. Errors, empty results, and
exceptions deny the fetch. Addresses are tried in resolver order, with duplicates
removed. The default resolver lists IPv4 addresses before IPv6 addresses.

Pinning applies to the built-in Req/Finch network transport. Host-supplied Req
adapters own their transport behavior; `Req.Plug` runs locally without opening
a network connection.
