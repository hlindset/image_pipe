# Bug hunt: image_pipe_url (URL builder, grammar, serializer)

Stopped early at the user's request. Code is at main `84eeac2`. The checks ran on Elixir 1.18.4 / OTP 25, because hex.pm and the mise builds are blocked in the cloud environment. Dependencies were cloned from GitHub instead.

Existing suite: 602 tests, 1 failure (`canonical_property_test.exs:219`). The failure is probably an OTP 25 `-0.0` artifact, so it is not a confirmed bug on the repo's OTP 29.

A builder round-trip probe covered about 100 option shapes: build the URL, run `Path.extract`, run `Parser.parse`, then compare against `Plan.to_spec`. Every generated URL parsed, and the text of every URL was correct. All mismatches are in canonical identity: the cache key differs while the output is the same.

## Confirmed

1. **Signature is malleable** (`lib/image_pipe/security/signature.ex`, `decode_signature/1`).
   `Base.url_decode64` ignores the 2 unused low bits in the 43rd character. Each signed URL therefore has 4 spellings that all verify. Example: `.../u10` and `.../u11` both return `{:ok, 0}`. The `enc/` token path already rejects non-canonical base64 (`canonical_token/2` in `source_encryption.ex`), but the signature path does not.
   Fix: re-encode the decoded signature and compare it with the input.

2. **Angles just below 0 normalize to 360.0 instead of 0.0** (`option_spec.ex` `normalize_angle/1`; builder `plan/builder/values.ex` `normalize(_, :direction)`).
   `fmod(-1e-20, 360) + 360.0` rounds to `360.0`. So `gradient=1,red,-0.000000000000000000001` gives angle 360.0, while `gradient=1,red,360` gives 0.0. `progressive-blur` has the same problem. The builder output `direction: -1.0e-20` also has angle 360.0, but its URL (`...,360,...`) parses to 0.0.

3. **The builder direction misses the parser's `-0.0` → `0.0` step** (`values.ex` `:direction`).
   `direction: -360` gives `-0.0` in the plan, while the parser gives `0.0`. On OTP 27+ these are different terms.

4. **Integer and float spellings give different canonical identity** for `crop`, `region` and the `trim` tolerance (both parser and builder).
   `crop=10,20` and `crop=10.0,20.0` produce different Specs, and so do `region=1,2,10,10` and `trim=red,10` against `trim=red,10.0`. Builder `crop: {10.0, 20}` keeps 10.0, but its URL `crop=10,20` parses to 10. So `ImagePipe.run/4` and the served URL build different Specs for the same request. The effect options already canonicalize this (`canonical_property_test`). These options don't.

5. **`-0.0` survives into the Spec** for `focus`, `region` origin, `trim` tolerance, `bg` alpha and autoquality `target`/`error` from the builder. `focus=-0.0,…` also does this in the parser. The URL text is the same in each case, but the terms differ on OTP 27+.

Severity: #1 is low to medium (no forgery, but the same image is reachable at 4 URLs). The rest are low: duplicate cache entries and run-vs-URL identity drift, with no wrong pixels.

## Not yet covered

- Preset expansion (`plan/presets.ex`), only read through.
- `validate_against` and `validate_known` behaviour.
- Encrypted watermark round trip through decrypt.
- Diagnostic renderer and format detector.
- A StreamData version of the round-trip probe.
