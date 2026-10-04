# Bug hunt: request handling

Scope: the Plug endpoint, URL parsing into plans, signing and encrypted URLs, presets, format negotiation, and response headers in `image_pipe` / `image_pipe_url` at commit 84eeac2.

How it was checked: Hex is blocked in this cloud environment, so `mise run precommit` can't fetch deps. Erlang 29.1.1 and Elixir 1.20.4 were built from source, and `image_pipe_url` was compiled against GitHub copies of its deps. Bugs 1, 2 and 5 were reproduced against that build. Bugs 3 and 4 need the full `image_pipe` dependency tree, so they were traced through the code and not run.

## 1. A preset lookup that returns a trailing newline crashes the request

- Where: `image_pipe_url/lib/image_pipe/api/value.ex:13` (`@nonneg_integer_pattern ~r/^[0-9]+$/`), which `dimension/1` and `pad_shorthand/1` use.
- Cause: In PCRE, `$` also matches just before a final `\n`, so `"10\n"` passes the regex. `String.to_integer("10\n")` then raises `ArgumentError`, and nothing rescues it.
- Reproduced:
  - `ImagePipe.API.Presets.parse_fragment("w=10\n")` raises `ArgumentError` instead of returning `:error`.
  - `"pad=1\n"` behaves the same way.
- Impact:
  - `ImagePipe.Presets.parse/1` only rescues around `fetch/2`, not around parsing. A `PresetLookup` backend that returns `"w=400\n"` (a common shape for text stored in a database) makes the request raise.
  - Expected result: the documented `{:preset, :invalid_definition}` and a 500 response.
  - `ImagePipe.run/4` and `validate/2` raise instead of returning that tuple.
  - Static presets also raise, but with a confusing message.
- Fix: use `\A...\z` anchors, as `option_spec.ex` already does. `@number_pattern` and `@css_name_pattern` in the same file have the same anchor problem, but their callers happen to fail safely.

## 2. Every signed URL has four valid signatures

- Where: `image_pipe_url/lib/image_pipe/security/signature.ex:73` (`decode_signature/1`).
- Cause:
  - A 43-character base64url string encodes 32 bytes plus 2 unused bits.
  - `Base.url_decode64/2` ignores those 2 bits, so four different last characters decode to the same MAC.
  - The `enc/` tokens already guard against this with `canonical_token/2` in `source_encryption.ex`. Signatures have no such check.
- Reproduced: for a builder-generated URL, all four variants of the last character return `{:ok, 0}` from `Security.verify/3`.
- Impact: low. Anyone can create up to four distinct URLs for one signed image. That fragments the CDN and browser caches, and it defeats any URL-keyed dedupe or allowlist.
- Fix: re-encode the decoded bytes and require an exact match, as `canonical_token/2` does.

## 3. A preset with `wm-enc` crashes the request on a mount without source encryption keys

- Where: `image_pipe/lib/image_pipe/plug/request.ex:105` and `:111-117` (`wm_enc_span/1`).
- Cause: When decryption reports `:source_encryption_disabled`, the code finds the error span with `{offset, _} = :binary.match(path, "/wm-enc=")`. If the `wm-enc` came from a static or looked-up preset, the raw path doesn't contain it. `:binary.match` then returns `:nomatch`, and the pattern match raises `MatchError`.
- Scenario:
  - Config: `request_watermarks: true`, `presets: %{"wm" => "wm-enc=AQID..."}`, and no `source_encryption_keys`.
  - Request: `GET /preset=wm/src/a.jpg`.
  - Result: the plug raises instead of returning the intended 400 diagnostic.
  - Nothing at config time rejects a `wm-enc` preset when no encryption keys are configured.
- Fix (either one):
  - Fall back to the preset span or the whole-path span.
  - Reject `wm-enc` in presets when source encryption is disabled.

## 4. Errors after processing starts replace the host's `Vary` header

- Where: `image_pipe/lib/image_pipe/plug/runner.ex:134` → `with_policy_headers/2` → `put_resp_headers/2` (`:254-261`).
- Cause: When `Execution.open` fails (415, 413, 422, 500, 501 or 503), the policy headers are written with `Plug.Conn.put_resp_header`. That replaces any `Vary` set by an upstream plug, such as `Accept-Encoding` or `Origin`, and it turns a host `Vary: *` into `Vary: Accept`. The success and 304 paths merge correctly through `CacheHeaders.merge_vary/2` (`cache_policy.ex:377`). This error path skips that merge.
- Impact: a shared cache can serve one variant's error to clients that should have got a different variant. For example, with host reflected-origin CORS that sets `Vary: Origin`, one origin's error can be served to another.
- Test sketch: copy the existing "cache-miss stream encode failures … preserve automatic Vary" test in `plug_test.exs` and add `put_resp_header("vary", "Accept-Encoding")`. Assert `["Accept-Encoding, Accept"]`. The current result is `["Accept"]`.

## 5. `Accept` weight `q=0.` is read as q=1, so the server sends a format the client refused

- Where: `image_pipe/lib/image_pipe/output/negotiation.ex:99-104` (`parse_quality/1`).
- Cause: RFC 9110 §12.4.2 allows `qvalue = "0" [ "." 0*3DIGIT ]`, so `0.` is a valid zero. `Float.parse("0.")` returns `{0.0, "."}`. The leftover `.` fails the `{quality, ""}` match, and the code falls back to `1.0`. I confirmed that `Float.parse` result.
- Scenario: `Accept: image/webp;q=0., image/jpeg` with a JPEG source gets WebP.
- Severity: low, because few clients send that spelling.
- Test: `assert Negotiation.modern_candidates("image/webp;q=0.", []) == []`.
- Fix: parse against `~r/\A(0(\.\d{0,3})?|1(\.0{0,3})?)\z/`.

## Suspicious, not confirmed

- **Commas inside quoted Accept parameters:** `Plug.Conn.Utils.list/1` splits `image/webp;x="a,b";q=0` on the comma, which drops the `q=0`. This is an exotic header shape.
- **HEAD on file-backed cache hits:** `response/sender.ex:131-137` sets `content-length` and then either sends an empty body or uses `send_chunked`. Whether that is correct depends on the adapter (Bandit or Cowboy). It couldn't be checked without deps.
- **CORS:**
  - There is no `Access-Control-Allow-Headers` on OPTIONS, so a cross-origin `fetch` that sends `If-None-Match` fails its preflight.
  - There is no `Access-Control-Expose-Headers` for `ETag` or `Content-Disposition`.
  - Both look like design gaps rather than bugs.
- **`must-revalidate` added alongside `stale-while-revalidate`** (`cache_policy.ex` `cap_control/3`): `must-revalidate` effectively cancels the stale window. This is documented, so it may be intended.

## Checked and found correct

- Signature verification happens before lexing.
- Query strings are rejected.
- `sig=` is only accepted as the first segment.
- `enc/` tokens are checked for canonical form and authenticated before decryption.
- Diagnostic bodies redact `sig`, `enc` and `wm-enc`.
- An expired URL returns 410 before the conditional check.
- `If-None-Match` handles lists and weak comparison.
- 304 responses use a header allowlist.
- `Vary: Accept` is sent on negotiated responses and left off for explicit `format=` and terminal outputs.
- Cache key and ETag inputs are consistent with the negotiated variant.
- `Content-Disposition` filenames are limited to `[A-Za-z0-9._-]`.
- 405 responses carry `Allow`.
