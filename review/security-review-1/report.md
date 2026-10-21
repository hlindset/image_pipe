# Security review 1

Review of `hlindset/image_pipe` at `main` `6a87579` (2026-10-21): the library, `image_pipe_url`, `image_pipe_server`, `image_pipe_svg`, the release images and CI. Report only: nothing in the repository was changed.

Six reviewers each took one area, read the code on main, and reproduced findings at runtime where it helped (`mix run` scripts, a running server, a forced crash). Their repro scripts are in `repro/` next to this file; the TOML files there hold only fake marker secrets. Each finding was checked against the earlier reports in `bug-hunt*/`, `perf-review*/` and `memory-leak-hunt/`, and the ones that repeat an earlier finding say so. Findings are numbered by area: S sources, K signing, F filesystem and cache, D decoding, H responses and logs, V server and supply chain.

## Overall picture

The main defences held up under targeted attempts to break them:

- **Signatures:** no bypass. The signed bytes are exactly the parsed bytes, the comparison is constant-time, and keys must be at least 32 bytes.
- **Source encryption:** A256CBC-HS512 is implemented correctly, with no padding oracle, and a concealed source never reaches the client.
- **SSRF:** no way past `allowed_hosts` or the address policy. Every resolved address and every redirect hop is checked, the connection is pinned to the checked IP, and numeric host spellings are denied.
- **File source:** no escape from its root by path or symlink.
- **Decoding:** a magic-byte allowlist runs before libvips, and the per-frame pixel limits and resvg hardening are in place.
- **Responses:** no header injection, and no active content types are served.
- **CI:** no injectable workflows, and actions are pinned by SHA.

Every earlier security-relevant finding the reviewers rechecked is fixed on main: hunt 1's four signatures, empty keys, Erlang distribution and Bearer case; hunt 3's key length and shared staging directory (one small leftover, F3); and hunt 5's log redaction.

What remains is mostly amplification (one request or one client doing many times the work or storage the limits were sized for), secrets reaching places they shouldn't (redirect targets, crash logs, telemetry), and supply-chain pinning.

## Summary

| ID | Finding | Severity |
|----|---------|----------|
| F1 | The cache cap counts only body bytes, so many tiny entries fill the disk and inodes and grow Admission's memory | Medium |
| S1 | Each request-chosen S3 bucket name starts a new credential fetch and a process that lives 5 minutes | Medium (low if signed) |
| D1 | No cap on distinct watermark assets: one request makes about 32 concurrent fetches and holds them all decoded (S4 is the same issue) | Medium |
| V1 | Slow clients hold every connection; 16 of them fail the liveness probe on `health_port` | Medium |
| H1 | A delivery coordinator crash logs origin credentials (no `format_status/1`) | Medium-low |
| V2 | The `-vision` image bakes in detection models from HuggingFace `main` with no pinned revision or checksum | Medium-low |
| H2 | `source_url` redaction misses common presigned and capability tokens | Low-medium |
| S2 | Custom secret headers such as `x-api-key` are forwarded on cross-origin redirects | Low |
| S3 | Redirects can downgrade https to http on a bare allowlist entry | Low |
| F2 | Client-controlled `storage_inputs` bypass both caches and download coalescing, even on signed URLs | Low |
| K1 | Concealed `enc/` tokens aren't bound to a signing key, so mounts that share encryption keys serve each other's concealed sources | Low |
| D2 | libvips' untrusted-loader block is never enabled; the magic-byte allowlist is the only gate | Low |
| D3 | `meta=keep` lets any request keep a source's EXIF, GPS and XMP, and a host can't pin this per mount | Low |
| H3 | A non-UTF-8 byte in the request path removes that request's text log line | Low |
| F3 | The staging directory's privacy is checked once per VM (leftover of hunt 3 #8) | Low |
| S5 | A few non-global address ranges count as public, and NAT64 isn't unwrapped | Low |
| V3 | The release build isn't fully pinned (base images by tag, rustup `stable`, first-party Hex packages outside the lock) | Low |
| V4 | The SVG release takes NIF checksums from the mutable GitHub release, after the approval wait | Low |
| V5 | `server.auth_token` and `stats.token` accept any non-empty string, with no rate limiting | Low |
| V6 | Cloud sessions install `bd` at `latest` with attestation checks off | Low |
| S6 | Userinfo in a redirect `Location` makes Req send Basic auth with origin-chosen credentials | Info |
| S7 | Credential URLs (`ContainerCredentials` `base_url`, STS `region`) are built from unchecked config strings | Info |
| K2 | The signature isn't bound to the mount, host or instance | Info |
| H4 | text/plain error bodies echo the path without `X-Content-Type-Options: nosniff` | Info |
| V7 | The Kubernetes example's security context is incomplete | Info |

The findings interact in places:

- S1 and D1 multiply each other: one request can name about 31 new buckets through watermarks.
- S2 and S3 combine to send an API key in plaintext.
- F1 is cheapest to reach through F2's unsigned `storage_inputs`.

Each area ends with its lower-confidence notes and a list of what was checked and found sound.


## Sources: SSRF and outbound fetching

In this part, a bare `#N` refers to `SN`.

Scope: `image_pipe/lib/image_pipe/source/http.ex`, `source/http/*`, `req_stream.ex`, `req_sanitizer.ex`, `parser.ex`, `routes.ex`, `auth.ex`, `origin.ex`, `download.ex`, `s3.ex`, `source/s3/*`, `execution/watermarks.ex`, `image_pipe_server/lib/image_pipe_server/config/sources.ex`, plus the Req 0.8.0-rc.0, Finch 0.24.0 and Mint 1.11.0 sources from hex.pm. Current main is `6a87579`. Repro scripts are in `repro/sources/` and were run with `mix run` from `image_pipe/`.

Short version: the HTTP SSRF defences hold up. Both the host allowlist and the address policy run on every hop, every resolved address is checked, the connection is pinned to the checked IP, and SNI, certificate checks and Host use the logical name. I found no bypass that lets a request reach a non-allowlisted host or a denied address. The findings below are about secrets leaking on redirect, request-driven amplification, and small policy gaps.

### S1. Request-chosen S3 bucket names each start a new credential fetch and a long-lived process

- **Severity:** medium on an unsigned mount that leaves `buckets` unset. Low when URLs are signed, because the attacker then needs a valid signature.
- **Location:** `image_pipe/lib/image_pipe/source/s3/credentials.ex:29-34`, `:57-62`; `image_pipe/lib/image_pipe/source/s3.ex:267`, `:317`, `:461-464`; `image_pipe/lib/image_pipe/source/s3/refresh_cache.ex:60-90`; idle retirement at `refresh_cache/entry.ex:37` (300 s)

**Evidence.** When `buckets` is nil, `bucket_config/2` accepts any bucket name. `prepare_cache/3` and `fetch/3` then call `Credentials.fetch(bucket, credentials)`, and the refresh-cache key is `{:s3_credentials, provider, opts, scope}`, where `scope` is the bucket from the URL. Each new name starts a new `RefreshCache.Entry` under the DynamicSupervisor, and that entry calls the provider right away. `InstanceRole`, `ContainerCredentials` and `WebIdentity` ignore the scope (`fetch_credentials(_scope, opts)`), so every one of these calls returns the same credentials. `AssumeRole` passes the scope down to its `base` provider, so each new bucket costs one STS `AssumeRole` call plus one base-provider fetch.

**Repro.** I ran `repro/sources/s3_scope.exs`: an S3 mount with `ContainerCredentials` pointed at a local endpoint, then 200 requests for `/src/s3://rnd-<n>/x.png`:

```
endpoint hits: [creds: 200, s3: 200]
new credential entry processes: 200
```

**Impact.** An unauthenticated client can send `s3://<random>/x.jpg` with a new bucket name each time. Each request makes one credential-endpoint call: IMDS (token PUT, role list, credentials GET), the ECS agent, or STS. Each request also leaves a process alive for at least 5 minutes. At a few hundred requests per second this means:

- IMDS or STS throttling, which can make the legitimate buckets' refreshes fail and end in `credentials_unavailable` (500) once their credentials expire;
- a warning-log flood when the provider fails;
- unbounded growth of processes and Registry entries.

With `request_watermarks: true`, one request can name about 31 more buckets (see #4). AWS STS quotas are shared account-wide, so the throttling can also affect other workloads in the account.

**Suggested fix.**

- Don't key credentials by request-chosen data unless the provider says it uses the scope. For example, the built-in providers could declare scope-independence, and the cache would then key on `{provider, opts}` only.
- Alternatively, or as well, reject bucket names that don't follow S3 naming rules before resolving credentials, and cap the number of entries.
- At minimum, the docs should strongly recommend `buckets` on mounts that serve unsigned URLs.

**Open question.** Does any real custom provider depend on per-bucket credentials? The `CredentialProvider` contract allows it ("must depend only on `scope` and the options").

### S2. Custom secret headers survive cross-origin redirects, including https to http

- **Severity:** low. It needs `max_redirects > 0` and an origin, or an open redirect on it, that redirects to another allowlisted host or to `http://` on the same host.
- **Location:** `image_pipe/lib/image_pipe/source/req_stream.ex:421-442`

**Evidence.** When a redirect leaves the origin (scheme, host or port changes), `redirect_options/2` drops `:auth` and `:aws_sigv4`. `strip_credentials/1` then removes only `authorization`, `proxy-authorization` and `cookie` from the headers. Every other configured header is sent to the next hop. That includes server TOML `request_headers`, which `sources.ex:209-216` turns into `req_options` headers.

`docs/serving-from-http.md:100-160` recommends exactly that setup: `x-api-key` for an origin, plus `max_redirects` with a second host (`images-eu.example.com`) in `allowed_hosts`.

**Repro.** I ran `repro/sources/redirect_headers.exs`. The allowlist was `localhost:P` and `127.0.0.1:P`, `localhost` redirected to `127.0.0.1`, and the configured headers were `x-api-key`, `x-goog-api-key` and `authorization`. The final hop received:

```
{"host", "127.0.0.1:47811"}, {"x-api-key", "SECRET-KEY"}, {"x-goog-api-key", "G"}
```

`authorization` was stripped, but the API keys were forwarded.

**Impact.** The API key meant for one origin goes to every other allowlisted host in a redirect chain. Allowlisted hosts are often third-party CDNs or storage. Combined with #3, the key can also go in plaintext to `http://` on the same host. That needs only the origin, or an open redirect on it, to answer with an `http://` Location. Whoever can see that traffic then gets the key.

**Suggested fix.** Across origins, drop every operator-configured header (keep a small allowlist such as `user-agent`), not just a denylist of three names. Or make which headers survive a redirect an explicit option. Also never forward headers when the scheme changes from https to http.

### S3. Redirects can downgrade https to http on a bare allowlist entry

- **Severity:** low
- **Location:** `image_pipe/lib/image_pipe/source/http/target_guard.ex:66-71`; `image_pipe/lib/image_pipe/source/http.ex:382-393`

**Evidence.** A bare entry is stored as `{host, nil}`, and `allowed?/4` accepts `port == default_port(scheme)` for *either* scheme. The default list built from an `https` `base_url` is also `{host, nil}`. So `TargetGuard.validate("http://assets.example.com/x", …)` passes for an entry meant for https. My repro printed `{:ok, …}` for both schemes. `follow/5` re-checks only the allowlist and the address policy, so an `https` → `http` redirect is followed.

**Impact.** After the downgrade, an on-path attacker can serve any image bytes, which then get cached (input and output caches) and served to every client of that URL. Secrets in custom headers (#2) are sent in plaintext. Mounts whose `match` only accepts `https` sources get downgraded by redirect anyway.

**Suggested fix.** Remember the scheme for each entry: a `base_url` entry allows only the base URL's scheme. Or refuse `https` → `http` redirects unless an option allows them.

### S4. With `request_watermarks`, one request fans out to about 31 concurrent source fetches

The same issue as D1, found from the fetch side; it is reported there, with this reviewer's runtime repro. Severity and fix are in D1.

### S5. Address policy: a few non-global IANA ranges count as public, and NAT64 isn't unwrapped

- **Severity:** low. It only matters when an attacker controls DNS for an allowlisted host, or the operator sets `allow_reserved`.
- **Location:** `image_pipe/lib/image_pipe/source/http/address_policy.ex:76`, `:89-106`

**Evidence.** `classify/1` returns `:public` for:

- `192.0.0.0/24` (IETF protocol assignments; the special-purpose registry marks it not globally reachable). This includes `192.0.0.192`, the Oracle Cloud Classic metadata endpoint listed in common SSRF payload lists. My repro: `{{192,0,0,170}, :public}`.
- `192.88.99.0/24` (6to4 relay anycast, deprecated).
- `2001::/23` IETF assignments such as Teredo `2001::/32` and ORCHID.

NAT64 `64:ff9b::/96` and `64:ff9b:1::/48` are classified `:reserved` as a whole, unlike IPv4-mapped and 6to4 addresses, which are classified by the IPv4 address inside. On an IPv6-only, DNS64 network an operator has to set `allow_reserved: true` to fetch anything. That also allows `64:ff9b::10.0.0.5` and other NAT64 addresses of private IPv4 hosts, plus documentation and benchmark ranges.

The "every address must pass" rule usually still rejects these, because the A record is checked too.

**Suggested fix.** Classify `192.0.0.0/24` (except `.9` and `.10`) and `2001::/23` as `:reserved`. Classify NAT64 addresses by their embedded IPv4 address, under a dedicated `allow_nat64` toggle, so the private or link-local categories still apply.

### S6. A redirect Location with userinfo makes Req send Basic auth with origin-chosen credentials

- **Severity:** info
- **Location:** `image_pipe/lib/image_pipe/source/req_stream.ex:403-436`; Req 0.8.0-rc.0 `lib/req.ex:590-595` (`url` with userinfo becomes `Map.put_new(:auth, {:basic, userinfo})`)

**Evidence.** Source URLs with userinfo are rejected (`parser.ex:118`), but redirect targets are not. A cross-origin hop drops `:auth`, and Req then turns `http://attacker:chosen@other-allowed/` into `authorization: Basic YXR0YWNrZXI6Y2hvc2Vu` (seen in `repro/sources/redirect_headers.exs`). No operator secret leaks. An origin can, however, make ImagePipe authenticate to another allowlisted host with credentials the origin picks. It also contradicts the parser's rule against userinfo.

**Suggested fix.** Reject a redirect Location that has userinfo (`{:source, :invalid_redirect}`), or strip it before building the next request.

### S7. Operator-configured credential URLs are built by string concatenation without validation

- **Severity:** info (configuration or platform environment only)
- **Location:** `image_pipe/lib/image_pipe/source/s3/container_credentials.ex:9-15`, `:199`; `image_pipe/lib/image_pipe/source/s3/sts.ex:89`

**Evidence.**

- `ContainerCredentials` restricts `full_uri` to https or a loopback, ECS or EKS host, "so the token can't be sent to another host". `base_url`, however, is unrestricted, and the auth token is sent to `base_url <> relative_uri`.
- `Sts.endpoint/1` builds `"https://sts." <> region <> ".amazonaws.com/"` from an unvalidated `region` (from `AWS_REGION` on the server). A value like `evil.example/x?` sends the web identity token or the signed AssumeRole request to `sts.evil.example`.

Separately, `full_uri` doesn't accept the EKS IPv6 endpoint `[fd00:ec2::23]`. That is a functional gap, not a security one.

**Suggested fix.** Apply the `full_uri` rule to `base_url`, and check `region` against `^[a-z0-9-]+$`.

### Lower confidence

- **`traceparent` is sent to origins (by reading).** When the tracer is attached and `trust_traceparent` is on, a trace ID the client chose reaches the origin (`telemetry/trace/req_step.ex`). Only `traceparent` is sent, never `baggage`, so I don't think this matters.

### Checked and found sound

- **Allowlist enforced before fetch and on every hop.** `HTTP.resolve/3` checks `allowed_hosts` with the port. `ReqStream.follow/5` runs `validate_target` on the initial URL and on every redirect (`URI.merge` + `TargetGuard.validate`). `target_guard(opts)` is merged last, so runtime options can't override it. Redirects are off by default, and the limit is enforced.
- **Address policy.** Every resolved address, IPv4 and IPv6 together, must pass (`Enum.all?`), and an empty answer is denied. Loopback, `0/8`, `::`, link-local (including `169.254.169.254`, `169.254.170.2`, `.23`), RFC 1918, CGNAT (Alibaba `100.100.100.200`), multicast, broadcast, `240/4`, ULA (`fd00:ec2::254`), site-local `fec0::/10`, IPv4-compatible `::a.b.c.d`, IPv4-mapped and 6to4 are all denied. The reroute path re-checks fresh answers, and cached DNS answers are re-checked on every use.
- **Numeric spellings.** `127.1`, `2130706433`, `0x7f.1`, `0177.0.0.1` and `[::ffff:127.0.0.1]` all parse to 127.0.0.1 and are denied (repro). Trailing dots, uppercase, `%`-encoding, `\@` and `%2f@` all fail the exact allowlist match: Elixir's `URI.parse` sees the userinfo, and the parser rejects it. The checker and Req both use `URI.parse` on the same string, and the connection goes to the pinned IP anyway.
- **DNS rebinding.** `PinnedTarget` rewrites the URL to the checked IP and sends the logical host in Host, Mint `:hostname` and SNI, so Mint checks the certificate against the hostname. Pools are keyed per address and hostname, so a connection is never reused for another name. The default adapter is `Req.Finch`, and `:adapter` and `:unix_socket` are rejected at config time.
- **Proxy environment variables.** Req, Finch and Mint don't read `HTTP_PROXY` or `HTTPS_PROXY`.
- **Response limits.** With `into: :self`, Req's `Decompress` step is skipped, so there are no gzip, br or zstd bombs. `max_body_bytes` applies to the raw bytes (`WrappedStream`), and `fetch_timeout` bounds chunked bodies with no length. Mint caps headers at 256 KB.
- **Origin headers and client headers.** Only a fixed set of origin headers is kept, for freshness, and the source's Content-Type is never served. Output is always re-encoded. No client request header reaches the origin except an opt-in `traceparent`.
- **Credentials on redirect.** `:auth`, `:aws_sigv4`, `authorization`, `proxy-authorization` and `cookie` are dropped across origins, including when only the scheme changes. Atom header names are normalized, so the old repeat bug #7 from hunt 1 is fixed.
- **S3.** The endpoint comes only from config, and there are no redirects. Bucket and key segments are fully percent-encoded, dot segments in keys are rejected after decoding, and ports and userinfo are rejected. Bucket names of `.` or `..` can only matter when `buckets` is nil, and then every bucket is served anyway.
- **Container credentials and IMDS.** The `full_uri` check matches the AWS SDKs. Metadata requests have redirects and retries off and bounded timeouts.
- **SVG (image_pipe_svg).** The `href` resolver returns nothing for external references, and roxmltree doesn't fetch external entities.
- **Server config.** An HTTP source still requires `allowed_hosts` or `base_url`, and request headers are checked for CR, LF and NUL. AWS environment values are merged before `ImagePipe.config` validates them, so `full_uri` from the environment is checked too.


## URL signing and source encryption

In this part, a bare `#N` refers to `KN`.

Scope: `image_pipe_url` security (`signature.ex`, `signature/keys.ex`, `source_encryption.ex`, `cbc.ex`, `hkdf.ex`), `api/path.ex`, `api/url.ex`, `url/config.ex`, the plug's parse flow (`plug/request.ex`, `plug/runner.ex`, `plug/errors.ex`, `plug/config.ex`), instance mounts (`instance.ex`, `config.ex` `put_url_options/2`), and the server's `auth.ex`, `router.ex`, `health.ex`, `stats.ex`, `config.ex`, `config/convert.ex`. Main at 6a87579.

How it was checked: I read the code. I ran scratch scripts with `mix run --no-start` in `image_pipe_server` (which compiles `image_pipe` and `image_pipe_url` as deps) to confirm the token-reuse finding, the encryption round trip and tamper rejection, mount key validation, and the redaction cost. Scratch scripts are in `repro/signing/`.

Overall: the signing and encryption design holds up. The MAC covers exactly the bytes the lexer parses. Nothing a client controls is processed before verification except the logged path, CORS registration and OPTIONS/405 routing. The AEAD construction is correct, and concealed sources go through the same source translation and resolution as plain ones. I found no way to bypass a signature. The one real finding is a key-scoping gap between mounts.

### Earlier findings in this area: status on main

| Report | Finding | Status |
|---|---|---|
| bug-hunt/request-handling.md #2 | Four valid signatures per URL | Fixed: `signature.ex:74-81` re-encodes and requires the exact spelling. |
| bug-hunt/request-handling.md #3 | Preset `wm-enc` crash without keys | Fixed: `request.ex:129-139` handles `:nomatch`. |
| bug-hunt/standalone-server.md #2 | Empty `IPS_URL__KEYS` / `_FILE` turns signing off | Fixed: `config/convert.ex:131-142` rejects an empty env list ("expected at least one entry"). An explicit TOML `keys = []` is still valid, by design. |
| bug-hunt/standalone-server.md #6 | `Bearer` matched case-sensitively | Fixed: `auth.ex:11-12`. |
| bug-hunt-3/url-builder.md #5 | No minimum key length | Fixed: `signature/keys.ex:12` requires 32 bytes. |
| bug-hunt-3/standalone-server.md #6 | One-byte key accepted | Fixed: server `config.ex:217-224` requires 32 bytes. |
| bug-hunt-6/request-handling.md #3 | `request_path` redaction costs ~30 ms before the signature check | Fixed (6c4a18c). The same crafted 10 KB path now takes 0.17 ms per call. |

---

### K1. Low: concealed `enc/` tokens aren't bound to a signing key, so a mount that inherits the instance's encryption keys serves another mount's concealed sources

- **Severity:** Low. It matters only when the mounts' signing keys are held by parties with different trust, such as tenants or separate apps. That is the use the `:mounts` docs suggest.
- **Location:**
  - `image_pipe/lib/image_pipe/instance.ex:25-37`: the `:mounts` doc says a mount's URL options apply "on top of the instance's own, so an option a set leaves out keeps the instance's value".
  - `image_pipe/lib/image_pipe/config.ex:835-851` (`put_url_options/2`) merges `config.raw` URL keys under the mount's own.
  - `image_pipe_url/lib/image_pipe/security/source_encryption.ex:9` uses one fixed AAD, `"image-pipe:source:v1"`, for every token.
- **Evidence:** a mount set such as `mounts: [partner: [keys: [kb]]]` on an instance configured with `keys: [ka], source_encryption_keys: [e]` inherits `e`. The token's AAD names no key, mount or purpose, so a token minted for mount A's URLs decrypts on mount B. Anyone holding `kb` can take an `enc/<token>` from any public URL that mount A serves and wrap it in a path they sign themselves. Reproduced at the security layer (`sig/t3.exs`):

  ```
  A's URL:  /sig=nplZ…/w=200/enc/AUV1RqMI…
  B-signed: /sig=8sYd…/w=4000/enc/AUV1RqMI…      (signed with kb)
  verify on mount B:  {:ok, 0}
  decrypt on mount B: {:ok, "https://private.example/x.jpg?X-Amz-Signature=secret"}
  ```

  The plaintext isn't shown to B's key holder; the server decrypts it internally. But B's key holder can fetch the concealed source with any options: full size, without the watermark or crop that A's URLs apply, or as `output=info`. They can do this without ever knowing the source. A concealed source is often exactly what B couldn't otherwise name: a private host, or a presigned URL whose credentials sit inside the token (`docs/urls.md:77-78` advertises this).
- **The same gap without instance mounts:** separate instances or servers that share `source_encryption_keys` but have different signing keys.
- **Impact:** cross-tenant access to concealed images on a shared instance. Within one mount, every accepted key is equally trusted, so there is no problem there.
- **Suggested fix (any one):**
  - Bind the token to its signer. For example, derive the per-mount encryption subkeys with HKDF over the mount's first signing key, or add a mount or key identity to the AAD.
  - Or make a mount set that overrides `:keys` also drop the inherited `source_encryption_keys` unless it sets them again.
  - Or, at minimum, document in the `:mounts` doc and `docs/urls.md#source-concealment` that every mount and server sharing the encryption keys accepts every concealed token, re-signed with any of its own keys.
- **Open question:** are differently-trusted signers an intended use of `:mounts`? The doc's example (`[signed: [keys: [key]]]`) and the fiddle use a signed mount next to an unsigned one. With an unsigned mount, a source's name is public anyway; only the concealed sources are protected.

### K2. Info: the signature isn't bound to the mount, the host or the instance, so one key shared across differently-configured instances lets URLs cross over

- **Location:** `image_pipe_url/lib/image_pipe/security/signature.ex:4-8`; `image_pipe/lib/image_pipe/plug/request.ex:146-148` strips the mount before splitting off the signature.
- **Evidence:** the MAC is HMAC-SHA256(key, mount-relative path) with no salt or domain tag. `docs/urls.md:34-37` documents that the host and mount path are outside the signature.
- **Impact:** a host that runs two instances or servers with different `sources`, presets or limits (say `/avatars` on a public root and `/internal` on a private root) under the same signing key accepts each one's signed URLs on the other. A URL signed for `/avatars/…/src/report.png` then reads `report.png` from the private root, if that file exists. A preset name also resolves to the other instance's definition. The attacker needs a signed URL whose path also makes sense on the other instance, so this is narrow.
- **Suggested fix:** a sentence in `docs/signing-urls.md` ("Generate a key") saying to use a separate key for each instance or server whose sources or presets differ. An optional per-instance salt (imgproxy's `IMGPROXY_SALT`) is an alternative, at the cost of a config option.

---

### Lower confidence / not worth a bead on its own

- **Fiddle demo keys are compiled in.** `fiddle/lib/image_pipe_fiddle/application.ex:8-9` hard-codes `String.duplicate("a1", 32)` and a fixed source encryption key. `fiddle/config/runtime.exs` has a prod block (`PHX_HOST`). A public fiddle deployment would let anyone decrypt its `enc/` tokens and sign URLs. The fiddle also has an unsigned mount on the same instance, so signing protects nothing there anyway. This is fine for a demo; reading the keys from the environment in prod would avoid the trap.
- **Deterministic tokens link URLs to the same source.** With the default `iv_mode: :deterministic`, the IV is HMAC(iv_key, source), so equal sources give equal tokens, and the token length shows the source length to 16 bytes. This is documented in `docs/urls.md:84-94`, with `:random` as the remedy. No action needed.
- **A server `auth_token` blocks browser CORS preflights.** `router.ex:108` checks auth before ImagePipe answers `OPTIONS`, and browsers never send `Authorization` on a preflight. The server has no CORS settings, so this only matters for a Plug host that puts a similar gate in front. This is interop, not security.

### Checked and found sound

- **What is signed.** The signed material is the raw bytes from the `/` after the `sig=` segment to the end of the mount-relative path (`path.ex:41-53`). `extract/2` lexes the same bytes (`lex_start/1`, `path.ex:115-127`). Neither normalizes anything, so there is no difference between what is signed and what is parsed.
  - A query string is a parse error after verification (`path.ex:87-92`).
  - `sig=` counts only as the first segment, and a later one is an error.
  - A leading empty segment (`//sig=…`) means no signature, so `403`.
  - Dot segments, empty segments and `%` in option segments are rejected.
  - `src` is percent-decoded exactly once, after verification.
  - `SIG=` isn't a signature.
  - Trailing slashes, `+`, case and extensions are all inside the signed bytes.
  - Output format by `Accept`, presets, `request_defaults` and preset lookups expand after verification by design (documented in `docs/urls.md:39-41`). Lookups run after verification (`request.ex:19-23`).
- **Mount stripping.** `mount_relative_path/1` drops `length(script_name)` raw segments and skips empty ones as `path_info` does. `Plug.forward/4` and the server router's `strip_prefix/2` both work by raw segment count, so the stripped part and `script_name` agree. Percent-encoded mount segments don't match the mount.
- **Comparison and format.** The comparison uses `:crypto.hash_equals/2`. The signature must be exactly 43 characters of canonical base64url, so truncated or padded signatures are rejected. Each key in the list is tried, and only the matching index is reported.
- **Keys.**
  - Every signing key must be at least 32 bytes (library and server).
  - Encryption keys must be exactly 32 bytes.
  - Encryption keys require signing keys (`security.ex:115-129`), including on instance mounts: `put_url_options(base, keys: [])` with inherited encryption keys raises "source encryption requires signing keys".
  - Signing and encryption keys must differ.
  - Empty env or `_FILE` lists are rejected.
- **`expires`.**
  - Request-scope, positive integers only (`option_spec.ex:1210-1215`; floats, zero and negatives are rejected). Bignums compare correctly.
  - The check is `expires < clock.()` on the system second clock (`processing.ex:66-68`), in `Processing.prepare`, before the conditional gate and the cache.
  - The value is inside the signed bytes.
- **Source encryption.**
  - A256CBC-HS512 per RFC 7518 §5.2.5: MAC key first, AL = 64-bit AAD bit length, tag truncated to 32 bytes.
  - The tag is checked with `hash_equals` before decryption and unpadding, so there is no padding oracle.
  - The token must be canonical base64url; version byte checked; ciphertext a non-empty multiple of 16.
  - The subkeys come from HKDF-SHA256 with a separate IV key.
  - Random IVs use `strong_rand_bytes`. An explicit IV is salted per watermark (the 0xFF prefix keeps those IVs disjoint from deterministic ones).
  - Every failure collapses to `:invalid_concealed_source`, which answers 404 "not found".
  - A decryption oracle would in any case need a validly signed URL, because the token is inside the signed bytes.
- **Concealed sources get the same checks.** A decrypted `enc` source is the same string a `src` source would be. It goes through `SourceParser.translate/2` and `Source.resolve/3` (`runner.ex:130-134`), as do `wm-src64` and `wm-enc` watermark sources (`execution/watermarks.ex:59-63`, `:158-160`). Request watermark sources stay gated by `request_watermarks` (`validation.ex:63-80`; `:watermarks` always defaults to `%{}`, so the gate always runs).
- **Nothing leaks the concealed source to the client.**
  - Diagnostics mask `sig`, `enc` and `wm-enc` (`path.ex:357-389`) and echo the raw, undecoded path as `text/plain`.
  - Signature errors are a terse 403.
  - `Content-Disposition` comes only from `filename`.
  - Debug headers need `allow_debug_headers`.
  - The `output=info` source facts carry no source path.
  - No origin response headers are passed through.
- **Unsigned endpoints.**
  - The library answers only OPTIONS (Allow and CORS headers) and 405 without a signature.
  - In the server, `/health/live|ready` (GET/HEAD) answer only `ok`, `starting` or `draining`.
  - `/stats` and `/metrics` need their own token on both listeners.
  - No image path can match either check, because image paths need a source marker.
- **Bearer tokens.** Exactly one `Authorization` header, a case-insensitive scheme, and the SHA-256 of the presented token compared with `Plug.Crypto.secure_compare/2` against the stored hash (constant time for any length). Empty `auth_token` and stats tokens are rejected.


## Filesystem, cache storage and staging

In this part, a bare `#N` refers to `FN`.

Reviewed on main at 6a87579. Paths are relative to the repository root. Runtime checks were run with plain `elixir` scripts; the project itself wasn't compiled (no `_build` when I ran them).

Counts: 1 medium, 2 low, plus lower-confidence notes and the areas I checked and found sound.

---

### F1. The cache cap counts only body bytes, so many tiny entries can fill the disk, use up inodes, and grow Admission's memory far past `max_size_bytes`

- **Severity:** medium (unsigned mounts, or any mount whose `storage_inputs` a client controls; see #2)
- **Location:**
  - `image_pipe/lib/image_pipe/cache/file_system/admission.ex:450-460` (`decide/3`), `:497-501` (`needed/3`)
  - `image_pipe/lib/image_pipe/cache/file_system/store.ex:826-845` (the descriptor size is the body size taken from the filename)
  - `image_pipe/lib/image_pipe/cache/file_system/policy.ex:20-23` (`score/2`)

**Evidence.** Admission tracks `stored_bytes` as the sum of `descriptor.size_bytes`, and that value is the body's byte length (`body_filename/4`, `parse_body_filename/1`). While the cache is under its cap, every write is admitted with no frequency check:

```elixir
needed <= 0 ->
  {:admit, []}
```

Each entry is in fact two files, `<hash>.meta` and `<hash>.<sha>.<size>.<cost>.body`, plus a row in Admission's ETS table. None of that is counted:

- An output-cache `.meta` for a complete body (blurhash, LQIP, info) is about 490 bytes (`term_to_binary` of the metadata map, measured).
- On ext4 and XFS each file takes at least one 4 KiB block and one inode. A 28-byte blurhash file shows `du` = 4096 here.
- Admission's table holds about 430 B per entry (memory hunt #3).

So a 28-byte blurhash entry is counted as 28 bytes. It actually takes about 8 KiB of disk, 2 inodes, and about 430 B of RAM, which is roughly 290 times the counted size. Small images such as `w=1/h=1` PNG or WebP (about 70 to 150 bytes) are similar.

The eviction score makes it worse once the cache is full. `score = freq × cost_us / size_bytes` heavily favours tiny entries, so a cheap 28-byte result beats a typical 50 KB image by two orders of magnitude. Attacker entries both get admitted and push out legitimate ones.

**Attack scenario.** On a mount without signing (`keys: []`, a common choice for internal or CDN-fronted setups), an attacker takes one image the source serves and requests `.../blurhash` (or `w=1/h=1`) with a fresh cachebuster or slightly different options each time. Each request costs one cheap processing run and leaves 8 KiB and 2 inodes behind.

- With `max_size_bytes = 10 GB`, the cap is reached only after about 350 M entries. That is about 2.8 TB of disk, 700 M inodes, and about 150 GB of Admission ETS memory.
- In practice the volume runs out of inodes or space, or the VM runs out of memory, long before the cap matters. A 20 GB ext4 volume has about 1.3 M inodes, so it is gone after about 650 k such requests, roughly an hour at 200 req/s.
- Operators size `max_size_bytes` to the volume, so they will assume the cap protects the disk.

On signed mounts the same works through client-controlled `storage_inputs` values (#2).

**Suggested fix.**
- Charge each entry for its real footprint in Admission: for example `size + meta_size`, each rounded up to 4 KiB, or a fixed per-entry overhead of about 8 KiB. Keep the body size in the filename for the startup scan and add the overhead when `put`/`decide` count it.
- Use the same charged size as the divisor in `Policy.score/2`, so tiny entries stop dominating.
- Consider an optional `max_entries` cap.

**Open question.** Are complete-body terminals (blurhash, LQIP, info) meant to share the image cache's byte budget at all? Their bodies are smaller than their own metadata.

---

### F2. Client-controlled `storage_inputs` (and the cachebuster on unsigned mounts) bypass both caches and download coalescing, even for signed URLs

- **Severity:** low
- **Location:**
  - `image_pipe/lib/image_pipe/representation.ex:87-96`: `input_key/3` includes `storage_only`.
  - `image_pipe/lib/image_pipe/execution/identity.ex` (`material/5`): `storage_only` is the cachebuster plus the `storage_inputs` header and cookie values.
  - `image_pipe/lib/image_pipe/execution.ex:176-186`: the main source gets its input key here. Download coalescing is keyed by `MaterialDigest.of(context.material)`, which includes `storage_only`.
  - `image_pipe/docs/cdn-http-cache.md:166-173`: the example config uses `{:cookie, "session"}`.

**Evidence.** The `storage_inputs` header and cookie values go into the output key, the originals-cache key, and the download-flight key. None of them is covered by the URL signature, and nothing limits how many distinct values a client can send. Each new value is therefore a miss in both caches and a new flight. The request then:

1. downloads the original again from the origin,
2. processes it,
3. writes a new originals-cache entry and a new output-cache entry.

The docs' own example partitions by a `session` cookie, a value every client sets freely.

**Impact.** One valid signed URL becomes unlimited origin fetches and processing runs, with cache churn: the originals cache admits everything while under its cap. URL signing is usually what stops cache-busting floods, and this setting quietly removes that protection. Combined with #1, small outputs also make storage grow without bound.

**Suggested fix.**
- Leave `storage_inputs` out of the originals-cache key and the download-flight key. They are documented as not changing the image and aren't sent to the source, so the original is the same for every value. The cachebuster can keep its effect on the input key if forcing a refetch is its purpose.
- Document that `storage_inputs` values must come from a trusted upstream, not directly from clients.
- Replace the `session` cookie example with something bounded, such as a tenant header set by a proxy.

**Open question.** Is a refetch of the original per `storage_inputs` value intended? `docs/cache.md:97-98` says the originals cache keys on these values, but the reason isn't given.

---

### F3. Leftover of hunt 3 #8: the staging directory's privacy is checked once per VM, so a directory removed later can be recreated by another local user

- **Severity:** low (hosts shared with untrusted local users, plus something that deletes `/tmp/image_pipe` while the VM runs, such as `systemd-tmpfiles` age cleanup on an idle server)
- **Location:**
  - `image_pipe/lib/image_pipe/cache/input.ex:186-226` (`private_dir/1`, `make_private/1`)
  - `image_pipe/lib/image_pipe/execution/source_cache.ex:507-516`, `:563-566` (`stage/5`, `spool/5`)

**Evidence.** The hunt 3 #8 fix is in place. The directory is made `0700`, its owner is checked against the VM's uid, a symlink is refused, staged files are opened `:exclusive` under random names, and each is `chmod 0600` right after it is created. The successful check, though, is cached for the VM's lifetime:

```elixir
case :persistent_term.get(key, false) do
  true -> :ok
```

If the directory disappears after that first check, `File.open(..., [:exclusive])` fails with `:enoent` and staging falls back to memory, which is safe. The unsafe case is when another user recreates `/tmp/image_pipe` (mode `0777`, owned by them) before the next staging. Then:

- The VM creates staged files in a directory the other user owns. Each file is created with the umask mode (usually `0644`) and only then `chmod 0600`, so the other user can open it for reading in that window and keep the descriptor.
- As owner of the directory, the other user can also rename the staged file and put their own at the same path. Decode reads the staged path by name, and `Store.open_linked_sink/5` hard-links it into the originals cache by name after the real bytes were hashed. The originals cache then stores the attacker's bytes under the real digest. Because it is a hard link to the attacker's inode, they can keep changing it (at the same size, which is all a hit checks).

**Suggested fix.**
- Check ownership and mode again cheaply before each staging (an `lstat` of the directory), or at least after an `:enoent`.
- Better: stage in a directory nobody else can name. That could be a per-VM random subdirectory created with `mkdir` (which fails if it already exists) under the private directory, or a staging directory under the originals cache root, which also makes the hard link always work.

---

### Lower confidence, not counted

- **Cache files and directories get umask modes (by reading).** `Owner.create/2` (`cache/file_system/owner.ex:65`) and `Store.in_partition/2` (`store.ex:863`) use `File.mkdir_p`, and bodies, metadata, and temp files are created with `:file.open`/`:file.write_file`. Under the usual umask 022 these come out as `0755` directories and `0644` files. Originals fetched with host credentials from private buckets or authenticated origins are then readable by every local user. Hard-linked staged bodies keep `0600`, but copied ones (staging on another filesystem, which is the normal case with a tmpfs `/tmp`) are `0644`. Only a multi-user host is affected, and the operator can make the root `0700`. The server image runs as one user. Suggest creating the root and partitions `0700` and files `0600`, or documenting it.
- **The file source checks the path, then opens it by name (TOCTOU, by reading).** `Source.File.fetch/3` resolves the path with `SafePath`, `stat`s it (following links), opens it to test readability, and staging or hashing opens it again by name. Someone with write access inside the root could swap a component for a symlink between the check and the open. That would read outside the root, or hang on a FIFO, since a raw `open` on a FIFO with no writer blocks. Anyone who can write the root is already mostly trusted, and uploads made through a web app don't create symlinks.
- **`root_id` uniqueness is checked only within one sources list (by reading).** `Routes.unique_file_roots/1` runs per `sources` list, and the cache context drops `:root` (`source.ex`, `location_options/1`). `ImagePipe.run/4` with a `sources:` override keeps the instance's caches (`config.ex:785-817`). A host that overrides sources per tenant with the same `root_id` but different roots would serve one tenant's cached results to another. This is documented ("must have the same `:root`") and only hosts can do it.
- **`storage: :allow` on an origin that sends `private` also sends `public` downstream (by reading, outside this area).** `limit_to_source/6` sees the source as storable, and `visibility/2` returns `public` in `:auto`/`:validators`. The option's docs describe it as ImagePipe's own storage, so a CDN caching the response may surprise the host. Worth confirming with the request-handling reviewer.
- **Cache-presence oracle (info).** `If-None-Match: *` gives `304` only on an output-cache hit (`plug/runner.ex`, `serve_output/2`), so a requester holding a URL can tell whether someone else already requested that variant. Timing reveals the same.
- **Early `304` for immutable file sources doesn't check that the file exists (info).** With `stable: :immutable`, the ETag comes from the path, so a matching `If-None-Match` gets `304` before any `stat`. It leaks nothing, because the answer doesn't depend on whether the file exists.

### Checked and found sound

- **Escaping the file source root.**
  - The `src` tail is percent-decoded exactly once (`image_pipe_url/lib/image_pipe/api/path.ex:283-322`), then split on `/`. `Routes.path_route/2` and `Source.File.validate_segments/1` reject empty, `.` and `..` segments and any `\`. So `%2e%2e`, `%2f..%2f` and `//` end up as rejected segments, and `%252e%252e` is a literal filename.
  - NUL is rejected in `Source.Parser` (`:nul_byte`); `:file` would return `:badarg` anyway (checked).
  - Absolute paths can't occur, since a leading `/` is stripped and segments can't contain `/`. Unicode isn't normalized, which is correct for byte filenames.
- **Symlinks inside the root (checked with a script against a copy of `SafePath`).** A relative link climbing out (`../../outside/s.jpg`) and an absolute link (`/etc/passwd`) are refused. Links that stay inside the root resolve, and link loops are refused. The resolved path is the one that is `stat`ed.
- **Devices, FIFOs, directories.** `regular_file/1` requires `type: :regular` after following links, so a FIFO, device or directory is `:not_found` (FIFO checked: type `:other`). `max_body_bytes` is checked on the `stat` size and again while streaming, so a growing file is cut off.
- **Cache key to filename.** Keys are SHA-256 hex digests. `partitions/1` requires 64 hex characters, body filenames are parsed strictly (lowercase hex, digits only), and partition directories are checked against the root with `SafePath` once per VM. Temp files use 16 random bytes and `:exclusive`.
- **`binary_to_term`.** There are only two calls in the whole repo (`image_pipe`, `image_pipe_server`, `image_pipe_url`, `image_pipe_svg`, `fiddle`), both in `store.ex:577,584`, and both use `[:safe]`. The retry loads the app's own modules, then decodes with `[:safe]` again. The decoded metadata is pattern-checked (`validate_metadata/1` in `store.ex` and `cache/file_system.ex`). Its content type is validated against the representation, and the headers are filtered again to the `vary`/`cache-control` allowlist at delivery (`response/sender.ex:59`). Funs or other terms in metadata are never called. A planted entry can at most serve planted bytes, which someone who can write the cache directory can do anyway.
- **Cache partitioning across sources and mounts.**
  - The main source's output key includes `source_partition`, its input key. That input key digests the effective fetch context: adapter options, frozen HTTP auth, and S3 configured credentials. So two sources reaching the same URL with different credentials never share entries.
  - Mounts of one instance differ only in URL settings (keys, encryption keys), which don't change the bytes.
  - Output policy material includes `strip_metadata`, `keep_copyright`, quality, and encoder options, so outputs that differ in privacy settings don't collide.
  - Two instances can't share a root: `Owner` makes the later claimant take over and the earlier one refuse.
- **Private origins.** Under the default `storage: :origin`, `no-store` and `private` responses aren't stored (`cache_state.ex:113-115`), and watermark assets that deny storage make the response unstorable (`execution.ex`, `cache_semantics/1`).
- **Debug data in cached entries** is shown only when the current mount has `debug?` (`sender.ex:377-392`).
- **ETag and 304** run after parsing and signature verification. Nothing is returned before the signature check.
- **Staging directory (hunt 3 #8).** Fixed apart from #3 above: owner check, `0700`, symlink refusal, exclusive random names, `0600` files. The sweep removes only matching names older than an hour and never the directory itself.


## Untrusted decoding and resource limits

In this part, a bare `#N` refers to `DN`.

Scope: `image_pipe/lib/image_pipe/decode.ex`, `decode/*`, `format/detector.ex`,
`transform/decode_planner.ex`, `transform/materializer.ex`, `transform/work_limits.ex`,
`transform/executor/step.ex`, `output/encoder.ex` (metadata), `config.ex` limits,
`execution/watermarks.ex`, and `image_pipe_svg/` (Elixir + the Rust NIF), at `main`
`6a87579`.

How it was checked: read all of the above plus the relevant `image` 0.72.0 and
`vix` 0.42.0 sources in `deps/`, and the libvips 8.18.7 loader source
(`jpeg2vips.c`, `svgload.c`, `foreign.c`) fetched from upstream. Inspected the
built libvips in `~/.cache/image_pipe/vips-8.18.7-heif-1.19.8` with `vips -l` and
`vips --vips-config`, and the server `Dockerfile`'s meson flags. The full
compiled `_build` was not available in this reviewer's container (shared with
other reviewers; I did not run `mix`), so the one concurrency/memory claim below
is reasoned from code, not measured — flagged as such. I did not build attack
image payloads.

Dedup: re-read bug-hunt-3/4/5/6 request-handling and image-processing reports.
The repeatedly-reported per-request CPU items (hunt-3 #1/#2, hunt-4 #4, hunt-5 #1,
hunt-6 #1 blur-budget-per-group, hunt-5/6 image #2 lazy-blur rebuffer) are all
either fixed or progressively mitigated on this `main`: `WorkLimits.convolution/2`
now accumulates `blur_work` across the whole request in `State`, and
`Step.settle/2` sets `rebuffer?` after each convolution so a later overlapping
read re-buffers instead of recomputing. Those are not re-reported.

### D1. No cap on the number of distinct watermark assets per request

- **Severity:** Medium. One request can force up to ~32 concurrent source fetches
  and hold up to ~32 full originals (raw bytes) plus ~32 decoded images in memory
  at once, each bounded only *per asset*, never in aggregate.
- **Where:**
  - `image_pipe/lib/image_pipe/execution/watermarks.ex:31-48` (`plan/2`):
    collects `group.watermark.asset` across all groups, `Enum.uniq()`, one plan
    entry per distinct asset. No count limit.
  - `:63-66` (`prepare_async/3`) and `:67-75` (`open_async/2`): map over the
    planned assets, starting one task per asset. Every asset's whole body is read
    into memory (`watermark.ex:217-241`, bounded by `max_body_bytes` *each*).
  - `image_pipe/lib/image_pipe/processing.ex:325-337` (`decode_watermarks/2`):
    `Enum.reduce_while` accumulates every decoded asset into one
    `%{asset => %{image: ...}}` map, all held simultaneously and handed to the
    executor as `:watermark_images`.
  - `image_pipe/lib/image_pipe/decode.ex:210-242` (`watermark/2`): each asset is
    limited by the same per-asset `max_input_pixels` (40 MP default) and
    `max_input_frames`, but nothing limits the *sum*.
  - URL side: a request path has up to 64 option segments
    (`image_pipe_url/lib/image_pipe/api/path.ex:27`, `@max_option_segments 64`).
    A group carrying only `wm-src64=<url>` plus a `-` separator is two segments,
    so ~32 distinct URL watermarks fit in one path. Each resolves through the
    source router (`watermarks.ex:58`, `Source.Parser.translate/2`).
- **Evidence / reasoning:** `plan/2` produces N distinct entries with no bound;
  `decode_watermarks/2` builds a map of all N decoded images before returning.
  The decoded asset images persist in `:watermark_images` for the whole transform,
  so peak memory is `main image + Σ(decoded watermark i)`. With N≈32 and each
  asset at the 40 MP per-asset ceiling (3–4 bytes/px), the decoded set alone is
  several GB; the raw bodies add up to 32 × `max_body_bytes` (320 MB at the
  default). The N fetches in `prepare_async`/`open_async` run as concurrent tasks,
  so N outbound requests fire at once (amplifying any SSRF reach the source
  network policy already allows, and multiplying connection/bandwidth cost).
  (Memory figure reasoned from code, not measured in this container.)
- **Impact / attack scenario:** Requires a mount whose watermark source routing
  accepts URL (`wm-src64`) watermark sources, and either an unsigned mount or a
  signing key. Given that, a single crafted URL (unique geometry per request to
  force cache misses) multiplies both outbound fetches and resident decode memory
  by ~32× over the single-image limits a host tuned `max_input_pixels` /
  `max_body_bytes` to bound. It is the watermark analogue of hunt-6 request #1's
  "work limits multiply by the number of groups": the per-asset input limits were
  sized for one image, and the group count defeats them. Named watermarks (from
  host config) are a fixed, trusted set and are not affected; this is specific to
  request-supplied URL watermarks.
- **Runtime repro (from the sources reviewer, `repro/sources/wm_fanout.exs`):** I ran `repro/sources/wm_fanout.exs`, with 31 groups and the origin sleeping 400 ms per response:
  
  ```
  origin counters: [max: 32, cur: 0, hits: 32]   elapsed ms 821
  ```
  
  That is 32 concurrent fetches, the main source plus 31 marks. With 33 groups the request is rejected with 400.
- **Suggested fix:** Give the request one aggregate budget for watermark inputs,
  not just a per-asset one: cap the number of distinct assets (a small fixed
  bound, or a `max_watermark_assets` host option) and/or cap `Σ decoded pixels`
  and `Σ body bytes` across all assets, failing with 400/422 at plan time before
  any fetch. A general `max_groups` cap after preset expansion (hunt-6 request #1's
  suggestion) would also bound this as a side effect.
- **Open question for the maintainer:** Is URL (`wm-src64`) watermarking expected
  to be used on mounts that also serve untrusted/unsigned traffic, or is it
  assumed signed-only? That determines whether this needs an aggregate budget or
  just a doc note.

---

### D2. `vips_block_untrusted_set` is never enabled

- **Severity:** Low (defense-in-depth gap; no demonstrated bypass).
- **Where:** No call to `vips_block_untrusted_set` / `VIPS_BLOCK_UNTRUSTED`
  anywhere (grep over `lib/`, `deps/vix`, `config/`, Dockerfile, scripts found
  none). `ImagePipe.Application.start/2`
  (`image_pipe/lib/image_pipe/application.ex:17-41`) sets no libvips operation
  policy, concurrency, or cache cap. The sole gate is the app-level magic-byte
  allowlist:
  - `image_pipe/lib/image_pipe/format/detector.ex:26-69` classifies the 32 KB
    peek by exact magic (first-match), falling to a bounded SVG structural scan,
    else `:unknown`.
  - `image_pipe/lib/image_pipe/decode.ex:43-44,485-488` (`gate_detected/1`)
    rejects `:bmp`, `:ico`, `:avif_sequence`, `:unknown` (and `:svg` without the
    SVG package) before any libvips open.
  - `image_pipe/lib/image_pipe/decode/source_format.ex:23-35` verifies the loader
    libvips actually chose matches the detected family, and
    `decode.ex:505-513` additionally guards the TIFF-signature→RAW-loader case.
- **Evidence / reasoning:** The allowlist is genuinely applied *before* libvips
  and is the right primary defense; I found no input that reaches an untrusted
  loader through it (PPM/Radiance/CSV/matrix/`.v`/raw all classify as `:unknown`
  and are rejected, since none produces an accepted magic prefix). The production
  server image also compiles libvips with `-Dmagick=disabled -Dpoppler=disabled
  -Dpdfium=disabled -Draw=disabled -Dopenslide=disabled` etc.
  (`image_pipe_server/Dockerfile:85-93`) and asserts `svgload|magickload|pdfload|
  dcrawload|ppmload` are absent. But the libvips used in **dev and test**
  (`~/.cache/image_pipe/...`, and anything a host links that wasn't built with
  those flags) ships `svgload`, `csvload`, `matrixload`, `vipsload`, `rawload`,
  `analyzeload`, `radload`, `ppmload` — all flagged `untrusted` by `vips -l`. The
  app's safety then rests entirely on the detector/loader-verify logic being
  bug-free; a single detection or loader-classification regression (e.g. a new
  accepted family whose loader libvips can be tricked into substituting) would
  have no backstop.
- **Impact / attack scenario:** No direct exploit today. This is a missing
  belt-and-suspenders: `vips_block_untrusted_set(true)` at boot would make libvips
  itself refuse the untrusted loaders regardless of how bytes were routed, and
  would protect hosts that link a stock libvips (Hex/precompiled vix, distro
  package) rather than the hardened server image.
- **Suggested fix:** Call the vix binding for `vips_block_untrusted_set(true)` at
  application start (vix 0.42 exposes operation NIFs; if no binding exists,
  request one upstream and set it via the NIF). It composes with, not replaces,
  the magic allowlist. File an `image`/`vix` upstream note if the binding is
  missing.
- **Open question:** Do you consider the hardened Dockerfile the only supported
  deployment, or is linking a stock libvips (e.g. the library used standalone via
  Hex) a supported path that should carry this backstop?

---

### D3. `meta=keep` lets a request keep a source's EXIF/GPS/XMP in the output

- **Severity:** Low (privacy; default is safe).
- **Where:**
  - `image_pipe_url/lib/image_pipe/api/option_spec.ex:387-391` exposes `meta` as a
    request-scope option; `image_pipe/lib/image_pipe/output/policy.ex:201-206`
    maps `meta=keep` to `{strip_metadata: false, keep_copyright: false}`,
    overriding the host's configured `strip_metadata`/`keep_copyright`.
  - `image_pipe/lib/image_pipe/output/encoder.ex:517-555` (`strip_metadata/2`)
    returns the image untouched when `strip_metadata: false`, so EXIF/GPS/XMP/ICC
    all pass through to the encoded output.
  - `config.ex:290-305`: `skip_processing_formats` serves the original unchanged
    including "any location data", bounded only by `max_body_bytes` (documented).
- **Evidence / reasoning:** The default is correct and privacy-preserving:
  `strip_metadata: true` and the default `meta=copyright` strip GPS/EXIF/XMP while
  keeping only copyright/artist (`encoder.ex:517-528`, verified against
  `image.minimize_metadata/2` in `deps/image/lib/image.ex:7483`). The gap is that
  `meta` is a plain request option with no host-side way to *pin* it: a host
  serving third-party/private originals cannot forbid requesters from flipping
  `meta=keep` and extracting the original's embedded GPS/camera-serial/XMP that
  the host intended to strip. On an unsigned mount this is available to anyone;
  on a signed mount it requires the key.
- **Impact / attack scenario:** A requester who can reach a source image through
  the proxy (but may not have the raw file) can recover its location/PII metadata
  by appending `meta=keep`, defeating the host's `strip_metadata: true`. Narrow,
  and only where the proxy fronts images whose metadata is more sensitive than the
  pixels.
- **Suggested fix:** Allow a host to fix the metadata policy for a mount (e.g. a
  config flag that makes `strip_metadata`/`keep_copyright` authoritative and
  ignores or 400s a request `meta` that would loosen it), or document clearly that
  `meta=keep` must be gated by signing when originals carry sensitive metadata.
- **Open question:** Is per-mount pinning of `meta` wanted, or is "sign the mount"
  the intended answer (as for the other request-controlled cost/behavior knobs)?

---

### Checked and found sound

- **Magic-byte allowlist before libvips.** `Detector.detect/1` +
  `gate_detected/1` run on the bounded peek before any libvips open; `:unknown`
  and the explicitly-rejected families never reach a loader. Signatures are exact
  prefixes at offset 0, mutually exclusive. The SVG structural scan is bounded
  (skips BOM/prolog/DOCTYPE incl. internal subset, tests only the root element)
  and punts to `:unknown` on anything ambiguous.
- **Loader verification.** `SourceFormat.verify/2` requires the loader libvips
  chose to match the detected family, and `verify_file_loader(:tiff, …)` closes
  the known TIFF-signature→RAW-loader substitution. `nocache` is irrelevant here.
- **Per-frame pixel limit covers animations/HEIF/TIFF.** `validate_pixels/3`
  multiplies `w × h × frames_decoded`; `frames_decoded/2` accounts for the
  composited canvases up to a requested `page` of a timed animation
  (`decode.ex:621-642`). `page_count/1` reads `n-pages`; `validate_frames/2`
  caps declared frames at `max_input_frames` (1000). Only the default image / the
  requested page is decoded — no `n: -1` / all-frames open anywhere (grepped).
- **WebP animation pre-count.** `WebpFrames.count/2` walks only 8-byte ANMF chunk
  headers (never payloads), stopping once over the limit, so an oversized animated
  WebP is rejected before libvips' quadratic header walk.
- **Header-dimension early reject (PNG/JPEG/WebP).** `HeaderDimensions.read/1`
  parses only declared SOF/IHDR/VP8* dimensions from the peek (consuming declared
  segment lengths, never scanning payloads) and feeds `validate_pixels`, catching
  the classic huge-declared-dimensions decompression-bomb shape before decode for
  these formats; other formats fall through to the libvips header open, which
  reports dimensions without decoding pixels, then `validate_pixels`.
- **libvips `fail_on: :error`** is passed on every open (`decode.ex` header_options
  and reopen, SVG excluded as it uses the NIF). libjpeg's warning policy aborts a
  corrupt progressive JPEG after 100 warnings unless `unlimited` is set, and
  ImagePipe never sets `unlimited` (confirmed in `jpeg2vips.c:352-357` and no
  `unlimited` option anywhere in the app).
- **resvg/usvg SVG hardening** (`image_pipe_svg/native/.../parse.rs`): external
  `href`s resolve to nothing (`resolve_string: |_,_| None`); `file://`/`http://`
  cannot be reached, so no SSRF or local-file read via `<image>`. Embedded `data:`
  images are accepted only when the declared MIME matches the sniffed signature
  (PNG/JPEG/GIF/WebP/SVG), gzip-SVG is refused, and each embedded raster's header
  pixels are checked against `max_image_pixels`. Entity expansion is pre-scanned
  and capped (`max_entity_expansion`), entities containing markup are refused
  (billion-laughs blocked), element count (`max_elements`), per-element and total
  text, and nesting depth (`MAX_DEPTH 1024`, reference depth `MAX_REFERENCE_DEPTH
  2048`, cycle detection) are all bounded before/around parse. Nested `data:` SVGs
  share the outer budget and are capped at `MAX_NESTING 2`. `MAX_NUMBER 1e15`
  rejects the arc-radius overflow DoS.
- **SVG CPU/memory budget.** `cost::estimate` walks the tree the way resvg
  renders (layers/filters/clips/masks/patterns/nested-SVG/decoded-image pixels,
  filter primitives weighted by cost), and `Decode.SVG.check_budget/2` enforces
  `max_render_work` and `max_render_pixels` (default 4× `max_input_pixels`) before
  `draw`. `fit_scale`/`check_pixels` cap the raster size at `max_input_pixels`.
  Fonts load only from host-configured dirs, never system dirs
  (`fonts.rs:203-234`).
- **Rust NIF won't take the BEAM down.** All four NIFs run on the DirtyCpu
  scheduler (`lib.rs:81,94,123,143`). Deep recursion runs on a 64 MB scoped
  thread (`with_stack`), and a panic in the worker is caught by `join()` and
  turned into `rustler::Error::RaiseAtom("panic")` rather than aborting. The one
  place a panic would abort (tiny-skia fixed-point overflow in a destructor) is
  pre-empted by the `MAX_EXTENT 32767` check in `render` before drawing. The
  render buffer length is `checked_mul` with `BadArg`/`enomem` on overflow/alloc
  failure. Resources are immutable after construction and marked `RefUnwindSafe`.
- **Materialization failures are decode failures.** `Materializer` returns
  `copy_memory` failures as `{:decode, _}` (→ 415) and the intermediate-pixel
  limit as `{:transform, _}` (→ 422), consistent with the contract.
- **Blur/sharpen budget is now request-wide** (`WorkLimits.convolution/2` +
  `State.blur_work`), and the lazy-convolution rebuffer (`Step.settle/2` →
  `rebuffer?`, `materialize/1` re-materializes when `rebuffer?`) closes hunt-5/6
  image #2.

### Lower confidence / not verified at runtime

- The peak-memory figure in finding #1 (several GB for ~32 max-size watermarks) is
  reasoned from the code holding all decoded assets in one map; I could not run a
  high-water benchmark in this container. The *direction* (no aggregate cap, all
  held at once, N bounded only by the 64-segment path cap) is certain from the
  code; the exact multiplier depends on how large an attacker can make each asset
  under the host's `max_input_pixels`.
- HEIF/AVIF grid and JXL header behavior: I reasoned from the libheif/libjxl
  header-read model (dimensions reported before pixel decode, then
  `validate_pixels` rejects) but did not feed a crafted oversized-grid AVIF or a
  huge-dimension JXL through the running decoder. Worth a targeted test if a
  reviewer has the decode path built: confirm an AVIF declaring, say, a
  100000×100000 grid is rejected by `validate_pixels` before libheif assembles
  any tile.
- The autoquality/`max-bytes` encode-search cost on large outputs at the *default*
  effort (hunt-6 reported ~30–47 s still) was not re-measured here; it is an
  encode-path item already tracked, outside a fresh decode/limit finding.


## Responses, logs and telemetry

In this part, a bare `#N` refers to `HN`.

Scope: `image_pipe/lib/image_pipe/{response,plug,delivery,output,debug,telemetry}`,
`telemetry.ex`, `source/req_sanitizer.ex`, and the server's `router.ex`,
`auth.ex`, `stats.ex`, `tracing.ex`, `config_error.ex`, `application.ex`.
Main at `6a87579` (includes PR #1055 `fix/source-url-telemetry` and
`1354270`, "Cut the logged path at the source and log the source parsed").

Runtime checks ran with `mix run` scripts in `image_pipe/` against Bandit
1.13.1 on localhost (scripts in
`repro/headers/`).

Earlier reports checked for duplicates: bug-hunt-5 request-handling #4 and #5
are fixed. bug-hunt-2 standalone-server #10 (client request ID) is fixed:
`trust_request_id` defaults to false, and a trusted ID must match
`[A-Za-z0-9\-_.:+/=]{1,200}`. bug-hunt-2 #1 and bug-hunt-3 #3 (TOML errors)
belong to the config reviewer and weren't re-checked. Nothing below repeats
an earlier report.

---

### H1. Medium-low: a delivery coordinator crash logs source credentials (bearer tokens, origin headers, S3 static keys)

- **Severity:** Medium-low. A secret leaks to logs only when the process
  crashes, but the leak is complete, and the codebase plainly means to
  prevent it: `Cache.Work`, `Cache.OutputWork`, `Source.Download` and
  `S3.RefreshCache.Entry` each define a redacting `format_status/1` for this
  reason.
- **Location:** `image_pipe/lib/image_pipe/delivery/coordinator.ex:28-45`
  (`defstruct` with `:config`) and `:86-107` (`init/1` stores the full
  request config). The module has no `format_status/1`.
  `image_pipe/lib/image_pipe/source/routes.ex:11` (`%Routes{}` derives no
  `Inspect` redaction).
- **Evidence:** `Delivery.stream/4` (`delivery.ex:77`) passes `context.config`,
  the whole request configuration, to `Coordinator.start/6`, and the
  GenServer keeps it in its state. That config contains
  `sources: %ImagePipe.Source.Routes{sources: %{name => {adapter, opts}}}`
  with the adapter options in plain text: HTTP `req_options` (`auth:
  {:bearer, token}`, `headers:` such as `x-api-key`, which is what the
  server's `bearer_token` and `request_headers` become) and S3
  `credentials: {:static, access_key_id: ..., secret_access_key: ...}`. The
  signing keys and source-encryption keys are safe, because `Keys` and
  `SourceEncryption` derive `Inspect, except: [...]`. `Routes` doesn't.

  Repro (`hl/coord.exs`): an inline mount with an HTTP source and
  `req_options: [auth: {:bearer, "SECRETBEARER"}, headers: [{"x-api-key",
  "SECRETHEADER"}]]`, origin on localhost. During a request, a telemetry
  handler finds the `{ImagePipe.Delivery.Coordinator, :init, 1}` process:
  - `:sys.get_status/1` on it contains both secrets.
  - Making it crash (an unhandled `GenServer.call`) logs the standard
    report: `GenServer #PID<...> terminating ... State:
    %ImagePipe.Delivery.Coordinator{... sources: %{web:
    {ImagePipe.Source.HTTP, [... req_options: [auth: {:bearer,
    "SECRETBEARER"}, headers: [{"x-api-key", "SECRETHEADER"}]] ...`. The
    request gets a 500.

  I didn't find a natural crash path in the coordinator. The trigger is any
  future bug that lets a `handle_*` clause or match in that module raise.
  The same unredacted `Routes` also appears whenever the config is an
  argument in the top frame of a `FunctionClauseError` stack trace (Bandit
  logs `Exception.format/3`, which inspects those arguments), and in
  `debug: true` raw dumps of exception events (see Lower confidence).
- **Impact:** Origin credentials reach stderr, container logs, and log
  shippers. With the server, that includes `bearer_token`,
  `request_headers` values, and static S3 keys.
- **Suggested fix:** Add `format_status/1` to the Coordinator that redacts
  `:config` (and `:build_fun`, `:request_context`), matching the other
  GenServers. For defense in depth, add `@derive {Inspect, except:
  [:sources]}` (or a custom `Inspect` that prints only source names and
  adapters) to `ImagePipe.Source.Routes`. That covers every way the config
  is inspected: crash states, stack-frame arguments, and `inspect` in debug
  logging. Add a test asserting that `inspect(config)` and
  `:sys.get_status(coordinator)` don't contain a configured bearer token.
- **Open question:** Should other long-lived processes that keep `config` or
  `cache_opts` (`Cache.Writer` state, `CredentialWarmup` state with provider
  `opts`) get the same treatment? I didn't confirm secrets in them.

### H2. Low-medium: `source_url` redaction misses common presigned and capability tokens

- **Severity:** Low-medium. Since `1354270`/PR #1055, every request line
  from the default Logger (on by default in the server, since `log_requests`
  defaults to `true`) and every trace span carries the decoded source URL.
  Only eight parameter names are redacted.
- **Location:** `image_pipe/lib/image_pipe/telemetry.ex:288-289`
  (`@credential_params`), `:324-370` (`source_url/1`, `redact_param/1`).
- **Evidence:** The list is
  `awsaccesskeyid signature sig x-goog-signature x-goog-credential
  x-amz-signature x-amz-credential x-amz-security-token`. Output of
  `ImagePipe.Telemetry.source_url/1` (`hl/su.exs`):

  ```text
  ...firebasestorage.googleapis.com/.../a.jpg?alt=media&token=1b2c-SECRET            (Firebase download token)
  ...supabase.co/storage/v1/object/sign/b/a.jpg?token=eyJSECRET                        (Supabase signed URL JWT)
  ...aliyuncs.com/a.jpg?OSSAccessKeyId=STS.x&Expires=1&Signature=REDACTED&security-token=SECRETSTS
  ...aliyuncs.com/a.jpg?...&x-oss-signature=SECRETSIG&x-oss-security-token=SECRETSTS   (OSS V4)
  ...myqcloud.com/a.jpg?...&q-signature=SECRETSIG&x-cos-security-token=SECRETSTS      (Tencent COS)
  https://cdn.example.com/a.jpg?__token__=exp=1~hmac=SECRET                           (Akamai)
  https://example.b-cdn.net/a.jpg?token=SECRET&expires=1                               (Bunny)
  https://f.backblazeb2.com/file/b/a.jpg?Authorization=SECRET                          (Backblaze B2)
  https://api.example.com/img?access_token=SECRET&api_key=SECRET2
  ```

  Each of these grants read access to the object until it expires, and the
  STS session tokens are part of temporary credentials. AWS, GCS and Azure
  spellings are redacted correctly, including `%2D`-encoded names, any
  case, `;` separators, and userinfo.
- **Impact:** A host serving presigned URLs from Firebase, Supabase, Bunny,
  Akamai, Backblaze, Alibaba, Tencent, or an API that takes `access_token` or
  `api_key` writes working capability URLs to its logs and trace backend. The
  docs say "A presigned URL's credentials, such as an `X-Amz-Signature`
  value, are replaced with `REDACTED`", which a reader will take as general.
  `enc` sources are decrypted into the same field, so a host that conceals
  presigned sources with `enc` also has them in its logs.
- **Suggested fix:** Extend the denylist at least with `token`,
  `access_token`, `api_key`, `apikey`, `key`, `authorization`, `__token__`,
  `hdnts`, `security-token`, `x-oss-signature`, `x-oss-credential`,
  `x-oss-security-token`, `q-signature`, `x-cos-security-token`,
  `x-obs-security-token`. Better: let the host add names (a
  `telemetry_redact_params` option). Or flip to an allowlist that redacts
  every query value unless the host names it as safe. Make the docs say the
  list is finite and give it.
- **Open question:** Denylist growth, a host-configurable list, or redacting
  all query values by default?

### H3. Low: a non-UTF-8 byte in the request path removes the request's log line (text log format)

- **Severity:** Low. Log evasion for failed requests: bad-signature probes,
  401s on the server's auth token, and 400s.
- **Location:** `image_pipe/lib/image_pipe/telemetry.ex:298-316`
  (`request_path/2` keeps raw bytes before the source marker, and the query
  when there's no source), used by `plug/runner.ex:47-51` and
  `image_pipe_server/lib/image_pipe_server/router.ex:125-136`. It reaches the
  line unquoted through `telemetry/logger.ex` `message([:request, :summary],
  ...)` (`meta[:path]` in the head).
- **Evidence:** Bandit rejects control bytes in the request line (`\e`,
  `\t`, `\x01`, `\x7f` give a bare 400 before the plug runs), but it accepts
  bytes `0x80-0xFF`. `source_url/1` got `String.replace_invalid/1` in
  `f082f24`, but the path didn't. Repro (`hl/sig.exs`, signed mount, default
  Logger):

  ```text
  GET /sig=AAAA/w=1/src/a.jpg       -> [warning] GET /sig=AAAA/w=1/src/REDACTED 403 7ms error=invalid_signature
  GET /sig=AAAA/w=1/src/a\xff.jpg   -> [warning] GET /sig=AAAA/w=1/src/REDACTED 403 0ms ...   (byte after src: cut, fine)
  GET /sig=AAAA\xff/w=1/src/a.jpg   -> 403, and the line becomes
      FORMATTER ERROR: bad return value
      [debug] ** (RuntimeError) bad return value from Logger formatter Logger.Formatter, got [<<255, 47, 119, ...
  ```

  The unsigned case is the same (`GET /w=1/x\xff\xfe/src/a.jpg` → 400, line
  replaced by `FORMATTER ERROR`). The server's own 401 and 404 lines go
  through the same `request_path/2`, so with `auth_token` set, an attacker
  guessing tokens with a `\xff` in the path leaves no request lines. A
  successful image request can't be hidden this way: an option segment with
  such a byte fails to parse, and bytes after the marker are cut. JSON log
  formats aren't affected: `LoggerJSON`'s encoder `inspect`s non-printable
  strings.
- **Impact:** Brute force against signatures or the server auth token, and
  scanning, can be kept out of text logs. The OTel span still records the
  raw path, unchanged.
- **Suggested fix:** Run the `request_path/2` result through the same
  sanitizing as `source_url/1`: `String.replace_invalid/1` plus
  percent-encoding of control characters. Add a summary-line test with a
  `\xff` in an option segment and in a `sig=` segment, plus a router test
  for the 401 line.

### H4. Info: text/plain error bodies echo the request path without `X-Content-Type-Options: nosniff`

- **Severity:** Info / hardening.
- **Location:** `image_pipe/lib/image_pipe/plug/errors.ex:113-121` and
  `:130-142` (diagnostic 400 bodies), `plug/diagnostic_renderer.ex`. The
  only `nosniff` in the library is on skipped originals
  (`output/skipped.ex:22`).
- **Evidence:** A 400 answers `content-type: text/plain; charset=utf-8` with
  the raw mount-relative path (up to 2 KB, with `sig`, `enc` and `wm-enc`
  masked) and caret labels. The 400 may carry the host's long
  `Cache-Control`. Current browsers don't sniff `text/plain` into HTML, so I
  know of no working XSS. Processed images also go out without `nosniff`,
  but their bytes are always re-encoded by libvips under a fixed `image/*`
  type.
- **Suggested fix:** Send `X-Content-Type-Options: nosniff` on every
  ImagePipe response (one `register_before_send`, like CORS), or at least on
  error bodies. Optionally add `Content-Security-Policy: default-src 'none';
  sandbox` on error and text bodies.

---

### Lower confidence

- **Raw exception reasons go unbounded to the tracer and Logger.**
  `trace/handler.ex:257` does `:otel_span.set_status(span_ctx, :error,
  inspect(meta.reason))`, and `telemetry/logger.ex:499` logs `inspect(reason)`
  for `:exception` events. `:telemetry.span/3` passes raw Erlang reasons
  (`{:badmatch, term}`, `{:case_clause, term}`), so a match failure on a
  value that holds config, a Req request, or headers would export it in
  full (`record_exception` itself is capped at 50 chars by the OTel API).
  I found no current raise carrying such a term. Source errors are
  normalized to atoms (`req_stream.ex:207-217`, `:495-510`). Suggest
  capping with `inspect(reason, limit: 5, printable_limit: 200)` or
  `Exception.format_banner/2` truncated.
- **`debug: true` dumps exception stack traces with arguments.**
  `logger.ex:108-112` logs `inspect(metadata)` for every event, and
  `:exception` metadata includes `:stacktrace`. A `FunctionClauseError`
  frame carries its arguments, which in request code often include `config`
  (see finding 1). Debug only, and documented as "raw", but worth a note in
  the docs or a stacktrace filter.
- **The default Logger puts every stage's metadata into Logger metadata.**
  `logger.ex:612-621` merges the whole metadata map, including `:reason`,
  `:stacktrace` and `:params`, into Logger metadata for stage lines. The
  server limits formatter metadata to `[:request_id, :image_pipe]`, but a
  library host whose formatter uses `metadata: :all` exports all of it.
  Probably fine. Consider passing only the keys the line renders.
- **Out of my area (sources):** cross-host redirects strip only
  `authorization`, `proxy-authorization` and `cookie` headers and the
  `:auth`/`:aws_sigv4` options (`source/req_stream.ex:421-441`). A secret
  in a custom header (`request_headers = { "x-api-key" = ... }`) is still
  sent to a different allowed host the origin redirects to. Passing to the
  source reviewer.
- **Different 404 bodies:** an `enc` token that no key decrypts answers 404
  `"not found"`, and a decrypted source that's missing answers 404 `"source
  not found"`. Tokens are AEAD-authenticated and the path is signed, so
  there's nothing to probe. Cosmetic.

---

### Checked and found sound

- **Header injection:** `filename` and `cb` accept only `[A-Za-z0-9._-]+`,
  so `Disposition.render/2` builds a safe quoted `filename=`. No origin
  header is passed through to the response: Content-Type comes from the
  encoder or detected format (`Format` MIME table), never from the origin.
  Cache entries keep only `vary` and `cache-control`, with control bytes
  rejected (`cache/entry.ex:8,105-127`). Debug headers render atoms and
  numbers; only the echoed `Accept` is client text, which can't hold CR/LF,
  and they need both `allow_debug_headers` and `debug`. Ignored-options
  header lists keys only.
- **Active content:** SVG is never an output format and can't be in
  `skip_processing_formats` (`config.ex:291-293`). Skipped originals get
  `nosniff` and a MIME type from the sniffed signature. Info is fixed
  `application/json` with numbers and format names, and placeholders are
  `text/plain`. No response reflects user input as HTML.
- **Source concealment in responses:** no response carries the source.
  Error messages come from fixed tables (`response/error_status.ex`).
  `{:invalid_source, _}` answers a fixed "invalid source". Info JSON has no
  URL. `Content-Disposition` never uses the source name. The ETag is
  `"ipr1-<digest>"`. Debug headers show a cache-key hash. Nothing redirects
  the client. Diagnostics mask `sig`, `enc` and `wm-enc`. Decrypted sources
  appear only in telemetry, as documented.
- **Request path in telemetry:** cut at the first `src`/`src64`/`enc`
  segment with a tail, the same split the lexer uses; `wm-src64=` values
  are replaced; a query is redacted only when there's no source (and the
  lexer rejects queries). The mount prefix is kept separately, so a mount
  segment named `enc` isn't treated as a marker. The router uses the same
  function.
- **Trace handler:** `@safe_keys` is an allowlist with no secret-bearing
  keys. `url.path`/`url.query` come from the cut path. `request_id` comes
  from Logger metadata, which the server generates unless
  `trust_request_id` is set. The Finch and Req spans carry only status and
  error type, never URL or headers. Outbound requests get `traceparent`
  only, not `baggage` or `tracestate`. Inbound `traceparent` is honored only
  with `extract_inbound`/`trust_traceparent`.
- **Log line injection:** Bandit rejects control bytes in the request line.
  `source_url` percent-encodes control characters. Summary values with a
  space, `"` or `=` are `inspect`-quoted. Request IDs are generated or
  restricted to a safe charset.
- **Secret structs:** `ImagePipe.Config` (`except: [:options, :raw,
  :url]`), `URL.Config`, `ImagePipe.URL`, `Signature.Keys`,
  `SourceEncryption`, `Execution.Inputs` (request headers and cookies),
  `Execution.Context`/`Output` all redact on `inspect`. The processing
  pool, `Cache.Work`, `Cache.OutputWork`, `Source.Download` and the S3
  refresh entry redact `format_status`. `CredentialWarmup` keys its child
  id on a hash of its options.
- **Server auth and stats:** bearer comparison hashes both sides with
  `Plug.Crypto.secure_compare` (constant time, scheme case-insensitive).
  Stats need their own token and answer 401 with `WWW-Authenticate:
  Bearer`. JSON log formatters include only `request_id` and `image_pipe`
  metadata.
- **CORS:** a host-chosen origin, never credentials, `Expose-Headers: *`
  and `Allow-Headers: *` only with `allow_origin`, stamped on every outcome.
- **HEAD / Range / 304:** HEAD sends the same headers without a body. Range
  isn't supported, and Req's `range` and the `range` header are stripped
  toward the origin when bytes are cacheable. 304 headers use an allowlist.
  5xx gets `no-store`.
- **Side channels:** on signed mounts, signature verification runs before
  any lexing or source access, with a terse 403 and no span echo. Source
  denials, unresolved hosts and origin 401/403/404/410 all answer 404
  "source not found".


## Server, release image, dependencies and CI

In this part, a bare `#N` refers to `VN`.

Scope: `image_pipe_server/` (lib, rel, config, Dockerfile, docs), every lockfile,
`.github/` (workflows, dependabot, renovate, local action), `repro/sources/*.sh`,
`mise.toml`, `.claude/settings.json`, and a skim of `fiddle/`. Checked on `main`
at `6a87579`.

Method: code reading, plus reproductions against the real server (`mix run
--no-halt` with a TOML file, Bandit 1.13.1, ThousandIsland 1.6.0, OTP 29.1.1).
`osv-scanner` is installed, but the proxy here answers 403 for
`api.osv.dev`, so the advisory checks below come from my own knowledge and
the version notes in the repo. No Docker image was built.

Deduplicated against `bug-hunt/` through `bug-hunt-6/standalone-server.md`.
Earlier security-relevant findings are fixed on main: distribution off by
default and bound to loopback (bug-hunt #1), the root-owned release
(bug-hunt-2 #13), h2c off (bug-hunt-4 #2), the 64-hex-digit minimum for
signing keys (bug-hunt-3 #6), the client-chosen request ID, and secret
redaction in TOML errors.

---

### V1. Medium: slowloris holds every connection slot. 16 trickling sockets fail liveness on `health_port`

- **Severity:** medium. Low for the image listener behind a buffering proxy or CDN.
- **Location:** `image_pipe_server/lib/image_pipe_server/application.ex:181-195`
  (health listener: `num_connections: 16`, `read_timeout: 5_000`, `ip` = `[server] bind`),
  `application.ex:203-220` (image listener), `config.ex:111` (`bind` defaults to `0.0.0.0`);
  Bandit `deps/bandit/lib/bandit/http1/socket.ex:97-101,173-181`.
- **Evidence:** Bandit applies `read_timeout` to each `recv` while it reads the
  request line and headers. It has no deadline for the request as a whole. A
  client that sends one header line just under every `read_timeout` keeps
  its connection forever. The limits are 50 headers of up to 10,000 bytes
  each, and one byte per interval within a header is enough. Reproduced with
  a Python script (`repro/server/slow.py`) that opens N sockets, sends
  `GET /x HTTP/1.1\r\nHost: a\r\n`, and then sends one `X-a: b\r\n` per second:
  - Image listener, `max_connections = 3`, `read_timeout = 2000`, 3 slow
    sockets: `/health/live` and `/health/ready` both got `ConnectionResetError`
    after 5.0 s, from ThousandIsland's 5 × 1 s wait and then a close.
  - Health listener (`health_port`), 16 slow sockets: `/health/live` was reset
    after 5.0 s. It answered `200` again once the sockets closed.
- **Impact:** The deployment guide's Kubernetes example points the
  `livenessProbe` at the health port (`docs/server-deployment.md:184-187`).
  That listener binds the same address as the image listener, so any peer
  that can reach the pod IP can open 16 sockets at a few bytes per second.
  Without a NetworkPolicy, that is every pod in the cluster. The kubelet then
  restarts the server in a loop, and the server drops all in-flight requests
  each time. The image listener (2048 slots) can be exhausted the same way
  from one host when it is reachable directly. A TLS terminator that buffers
  whole request headers before proxying (nginx, ALB, Caddy, Traefik, CDNs)
  shields the image port, but not the health port. The guide says
  `read_timeout` "closes connections that send nothing for that long", which
  is accurate, but readers may take it as slowloris protection.
- **Suggested fix:**
  - Add a `[server] health_bind` setting (or document binding the health
    listener to a non-routable address), and recommend a NetworkPolicy in the
    Kubernetes example.
  - Raise the health listener's cap, or let it shed its oldest idle
    connection.
  - For both listeners, a header deadline is the real fix. Bandit has no
    option for one, so it needs either an upstream feature request (a
    `request_header_timeout`) or a small ThousandIsland handler wrapper that
    closes a connection whose first request hasn't completed within N
    seconds.
  - Document that the image port should sit behind a header-buffering proxy.
- **Open question:** Is the health port ever reachable from outside the pod
  network in the deployments you run (Bunny, uncloud)?

### V2. Medium-low: the `-vision` release image bakes detection models fetched from HuggingFace `main` without a pinned revision or checksum

- **Severity:** medium-low (supply chain).
- **Location:** `image_pipe_server/Dockerfile:152-160` (build-time
  `Detector.warmup(detector, classes: :all)`); `image_vision` 0.4.0
  `lib/image_vision/model_cache.ex` (`download!/3`:
  `url = "#{@hf_base_url}/#{repo}/resolve/main/#{filename}"`, no hash check);
  repos `opencv/face_detection_yunet` (`face_detection.ex:54`) and
  `onnx-community/rtdetr_r50vd` `onnx/model.onnx` (`detection.ex:50-51`).
- **Evidence:** The release workflow builds the vision variant
  (`release-server.yml:147,180`) and downloads whatever those third-party
  repositories serve at `main` at build time. Nothing records or verifies the
  file hashes. The files land in `/opt/image_pipe/cache`, and ONNX Runtime
  parses and runs them on every detection request.
- **Impact:** A change or compromise of either HuggingFace repository, or of
  the HF account, goes into the next published `ghcr.io/…:X.Y-vision` image
  without review. The plain effect is silently different crops. The worse
  case is a crafted ONNX file aimed at a parser bug in the bundled ONNX
  Runtime (`ortex` 0.1.10 → `ort` 2.0.0-rc.8, an ORT 1.19-era runtime), run on
  untrusted image input in the server process. Builds are also not
  reproducible.
- **Suggested fix:** In the Dockerfile, after the warmup, check the baked
  files against a committed `sha256sum -c` list, and fail the build on a
  mismatch. Better still, download the pinned HF revision URLs
  (`resolve/<commit>/…`) into the cache path yourself. Record the gap in
  `image_vision` (no revision or checksum option) for its maintainer.

### V3. Low: the release build isn't fully pinned (base images by tag, unpinned rustup, first-party Hex packages outside the lock)

- **Severity:** low (supply chain and reproducibility).
- **Location:**
  - `image_pipe_server/Dockerfile:18-19`: `hexpm/elixir:…-trixie-20260918-slim` and
    `debian:trixie-20260918-slim` are referenced by tag, not `@sha256:`.
  - `.github/actions/docker-buildx/action.yml`: they are pulled through
    `mirror.gcr.io`.
  - `.github/dependabot.yml`: no `docker` ecosystem, and Renovate is limited
    to mise.
  - `Dockerfile:108-110`: `curl -fsSL https://sh.rustup.rs | sh -s -- -y --default-toolchain stable`
    floats, while `mise.toml` pins Rust 1.98.1. It runs in release vision
    builds and in path-mode CI builds.
  - `image_pipe_server/mix.exs:54-70` and `image_pipe/mix.exs:297-299`: in
    `IMAGE_PIPE_LIBS=hex` mode, `image_pipe`, `image_pipe_url`, and
    `image_pipe_svg` aren't in `image_pipe_server/mix.lock` (verified: the
    lock has 49 packages and none of the three). `mix deps.get --only prod`
    therefore resolves them fresh at image build time, and `image_pipe_svg`
    floats within `~> 0.1.0`.
  - The runtime stage runs `apt-get install` without `apt-get upgrade`, so
    base-layer packages such as libc6 stay at the date of the snapshot tag.
- **Impact:** A published release image contains whatever the tag, the
  mirror, rustup's `stable`, and the newest Hex `image_pipe_svg` 0.1.x were
  at build time. A retagged base image or a new `image_pipe_svg` patch
  release ships without review, and nothing alerts when the Debian snapshot
  goes stale. Hex verifies package checksums against its signed registry,
  and the NIF download is checksum-pinned (see the sound items below), so
  this is about drift and review, not unauthenticated code.
- **Suggested fix:**
  - Pin both `FROM` images by digest, keeping the tag in a comment, and add
    `package-ecosystem: docker` for `/image_pipe_server` to Dependabot so the
    digests get bumped.
  - Install a pinned Rust (`--default-toolchain 1.98.1`, checked by
    `repro/sources/check-toolchain.sh`).
  - Commit a hex-mode lock (for example
    `image_pipe_server/mix.hex.lock` via `lockfile:`), or pin
    `image_pipe_svg` with `==`.
  - Optionally run `apt-get upgrade` in the runtime stage, and rebuild
    release images on a schedule.

### V4. Low: the SVG release computes NIF checksums from the mutable GitHub release, after the approval wait

- **Severity:** low (requires repo write access or a leaked token).
- **Location:** `.github/workflows/release-svg.yml:85-156`.
- **Evidence:** The `github-release` job publishes the NIF assets. The `hex`
  job then waits for the `release` environment (an approval, if one is
  configured) and builds `checksum-*.exs` with `mix
  rustler_precompiled.download … --all --print`, which downloads the assets
  from that release again. The checksums aren't compared with the build
  artifacts the `nif` jobs uploaded.
- **Impact:** Anyone who can edit release assets between the two jobs can
  swap a binary, and the Hex package then pins the swapped one. Every
  `image_pipe_svg` user, including server images built in hex mode, would
  load it as a NIF. The approval wait makes the window as long as the
  approval takes. After publishing, the checksum file catches a swap.
- **Suggested fix:** Compute `sha256` for each artifact in the
  `github-release` job, pass the list as an artifact, and have the `hex` job
  fail if the downloaded files don't match. Turn on GitHub immutable releases
  for the repository.

### V5. Low: `server.auth_token` and `stats.token` accept any non-empty string, with no rate limiting

- **Severity:** low.
- **Location:** `image_pipe_server/lib/image_pipe_server/config.ex:393-417`;
  `auth.ex:391-397`.
- **Evidence:** `auth_token_hash!/1` rejects only `""`, and the stats token
  check is the same. `auth_token = "x"` boots, and nothing limits failed
  attempts. Signing keys, by contrast, now need 32 bytes (`config.ex:217-224`).
- **Impact:** A placeholder token such as `secret` or `changeme` lets anyone
  bypass the auth gate, which is meant for unsigned URLs behind a trusted
  edge, or read `/stats` and `/metrics`. Brute force is limited only by
  network speed.
- **Suggested fix:** Require at least 16 bytes for both tokens, or log a
  warning at boot for shorter ones. Say "a random value of at least 32
  characters" in the docs.

### V6. Low: dev-environment tooling installs `bd` at `latest` with mise attestation checks off

- **Severity:** low (developer and agent environments only. CI doesn't install it).
- **Location:** `mise.toml:12` (`"github:gastownhall/beads" = "latest"`);
  `repro/sources/cloud-session-start.sh:32-33,152-153`
  (`MISE_GITHUB_GITHUB_ATTESTATIONS=false`, then `mise install`); there is
  no `mise.lock`.
- **Impact:** Every cloud session runs whatever the newest beads release is,
  with no cooldown and no provenance check. That session also holds
  `DOLTHUB_CREDS_JWK` and the repository's git credentials. Renovate's
  14-day `minimumReleaseAge` doesn't apply, because `latest` is never bumped.
- **Suggested fix:** Pin a beads version and let Renovate bump it. Consider
  `mise` lockfiles (`[settings] lockfile = true`) so tool downloads are
  checksum-pinned even with attestation checks off.

### V7. Info: Kubernetes example lacks the rest of the "restricted" security context

- **Location:** `image_pipe_server/docs/server-deployment.md:166-192`.
- **Evidence:** The example sets `runAsNonRoot`, `runAsUser`, and
  `readOnlyRootFilesystem`. It doesn't set
  `allowPrivilegeEscalation: false`, `capabilities: { drop: [ALL] }`, or
  `seccompProfile: { type: RuntimeDefault }`. The server needs none of what
  those take away (it listens on 8080), so adding them costs nothing, and it
  limits what an exploit in a libvips or ONNX decoder can do.
- **Suggested fix:** Add the three lines. Suggest `cap_drop: [ALL]` and
  `security_opt: [no-new-privileges:true]` in the Compose example as well.

---

### Lower confidence

- **Opt-in distribution still uses the build-time cookie.** With
  `RELEASE_DISTRIBUTION=sname|name`, epmd and the node bind to 127.0.0.1
  (`rel/env.sh.eex:246-257`), but the cookie is still the public
  `releases/COOKIE` from the image. In a Kubernetes pod, sidecars share
  loopback, so a compromised sidecar could connect and run code as uid
  10001. Only an operator who turns distribution on is exposed. Suggested
  fix: when `RELEASE_COOKIE` is unset and distribution is on, have `env.sh`
  generate a random cookie into `$RELEASE_TMP` (0600) on first start and
  reuse it for `remote`.
- **Defense in depth for libvips loaders.** The Dockerfile disables the
  risky optional loaders and asserts that several are absent. It doesn't
  set `VIPS_BLOCK_UNTRUSTED=1`, which would also block the built-in loaders
  libvips marks untrusted (matrix, csv, vips). ImagePipe's decode already
  verifies that the loader matches the detected family (`decode.ex:490-503`),
  so this only matters if that check has a gap. The decode reviewer should
  confirm.
- **`ort` binary download.** `ortex` builds `ort` 2.0.0-rc.8, which
  downloads a prebuilt ONNX Runtime at compile time. I didn't confirm whether
  `ort-sys` verifies that archive's hash. I also didn't check the bundled ORT
  version against ORT CVEs.
- **`req` 0.8.0-rc.0** is a release candidate in the production locks of
  `image_pipe`, the server, and the fiddle. I know of no advisory against
  it. Noted as a maturity risk on the source-fetch path.

---

### Checked and found sound

- **Erlang distribution:** off by default (`RELEASE_DISTRIBUTION=none`), and
  loopback-only when on (bug-hunt #1, fixed). The smoke test covers both.
- **Container:** the server runs as uid 10001, `/app` and the models are
  root-owned, only `/var/cache/image_pipe` is owned by the runtime user,
  everything the release writes goes to `/tmp`, the smoke test runs
  `--read-only --tmpfs /tmp`, and the HEALTHCHECK has a sane interval. The
  image has `curl`, `sh`, and the `openssl` CLI, which is only post-exploit
  convenience.
- **Secrets in crash dumps:** I booted the server with a signing key, an
  `auth_token`, and static S3 credentials, then forced
  `:erlang.halt(~c"forced")`. The 10 MB dump contained none of them, in
  ASCII or hex. The file was created 0640. `ImagePipe.Config`, the URL
  config, the signing keys, and source encryption use redacting `Inspect`,
  and credential warmup child ids hash their options. Config errors halt
  with `System.halt(1)`, which writes no dump.
- **Logging:** text and JSON formatters emit only `request_id` and
  `image_pipe` metadata, so Bandit crash metadata (`conn`) isn't printed.
  Router-logged paths are cut at the source.
- **Auth:** the bearer token is compared as SHA-256 digests with
  `secure_compare`, and the scheme is case-insensitive. Health checks skip
  auth, stats has its own token on both listeners, and stats output carries
  no paths or secrets.
- **HTTP:** h2c is off on both listeners, so HTTP/2 rapid reset doesn't
  apply. Bandit's header limits are at their defaults (10 KB request line,
  10 KB per header, 50 headers). Bandit 1.13.1 includes the fixes for
  GHSA-69m6-wcv4-rwcf and GHSA-v53v-9hvg-37jf (noted in `mix.exs:39`).
- **Downloads in the Dockerfile, CI, and cloud setup:** zlib-ng, libpng,
  libjpeg-turbo, libvips, and libheif are fetched over HTTPS and checked with
  `sha256sum --check --strict`. The libvips version and hash match across
  the Dockerfile, `elixir.yml`, and `cost-calibration.yml`.
- **rustler_precompiled:** `image_pipe_svg` downloads from its own GitHub
  release, the package ships `checksum-*.exs` covering all 7 targets × 3 NIF
  versions (`release-svg.yml` matrix = `native.ex` targets), and
  `force_build` is set only from config (`dev`/`test`, or
  `IMAGE_PIPE_LIBS != hex`). Whoever controls those variables already
  controls the build.
- **GitHub Actions:**
  - Every third-party action is pinned by SHA and Dependabot updates them
    with a 14-day cooldown.
  - Every workflow defaults to `permissions: contents: read`, and every
    checkout sets `persist-credentials: false`.
  - No workflow uses `pull_request_target` or `workflow_run`.
  - Every `${{ }}` in a `run:` step is a matrix value or a SHA from
    `git rev-parse`. PR fields reach scripts only through `env:`.
  - Publish secrets (`HEX_API_KEY`) appear only in tag- or dispatch-triggered
    jobs behind the `release` environment.
  - Image tagging waits on the `release-server` environment.
  - Releases check that the tag is on `origin/main`.
  - `release-docs.yml` refuses refs that change anything but `.md` files and
    doc assets since the tag.
- **Performance workflow:** `pull_request` only. Fork PRs get a read-only
  token, and the comment step is skipped for them. For same-repo PRs, PR
  code runs in a job whose token has `pull-requests: write`, but those
  authors already have write access.
- **Caches:** GHA and BuildKit `type=gha` caches written by pull requests
  are scoped to the PR ref, and release builds read only main's caches, so a
  PR can't poison them.
- **Advisories (version-matched, from my knowledge; OSV unreachable here):**
  no known advisory for plug 1.20.3, bandit 1.13.1, thousand_island 1.6.0,
  mint 1.11.0, finch 0.24.0, hpax 1.1.0, jason 1.4.5, telemetry 1.4.2,
  opentelemetry 1.7.0 / api 1.5.0 / exporter 1.11.0, chatterbox 0.16.0,
  tls_certificate_check 1.35.0, ssl_verify_fun 1.1.7, toml 0.7.0 (its
  robustness bugs are covered by earlier hunts), rustler 0.38.0,
  rustler_precompiled 0.10.0, resvg/usvg 0.48.1, libvips 8.18.7, libpng
  1.6.59, libjpeg-turbo 3.2.0, or zlib-ng 2.3.3. The weekly `Audit`
  workflow runs `osv-scanner` over every lockfile.
- **Fiddle:** standard Phoenix layout. The dev and test `secret_key_base`
  values are committed, and prod requires `SECRET_KEY_BASE`. `check_origin:
  false` is set only in dev. The demo signing and encryption keys are meant
  to be public. The HTTP source is limited to loopback hosts and is opt-in.
  No open proxy.
- **Worktree hook:** `worktree-create.sh` reads the name with `jq` and quotes
  every use of it.

