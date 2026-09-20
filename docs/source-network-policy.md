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
exceptions deny the fetch.

## Known limitation: DNS rebinding

This policy resolves and validates but does not pin the connection. The HTTP
client resolves the hostname again when it connects, so a DNS-rebinding attacker
could return a public address during validation and a private address during the
connection. Preventing that requires connecting to the validated IP.
