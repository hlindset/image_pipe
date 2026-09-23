# Conservative Format Auto Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to run this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make automatic output conservative when `Accept` is missing, empty, or only global wildcard, while preserving explicit AVIF/WebP negotiation.

**Architecture:** `ImagePipe.Output.Negotiation.modern_candidates/2` already feeds both output policy selection and automatic cache key data. Treat global wildcard-only headers as no modern-format signal there. Leave source fallback, `Vary: Accept`, telemetry, limits, transforms, and cache headers unchanged.

**Tech Stack:** Elixir, ExUnit, StreamData, Plug, Boundary-enforced `ImagePipe.Output.*` and `ImagePipe.Cache.*`.

---

## Discovery Notes

- Issue #50 clarifies that automatic output is an omitted output format, not `format:auto`; parser tests already reject `format:auto`.
- `lib/image_pipe/output/negotiation.ex` parses `Accept` and returns `[:avif, :webp]` for `*/*`.
- `lib/image_pipe/output/policy.ex` uses that candidate list to choose modern output before source fetch and always adds `Vary: Accept` for automatic output.
- `lib/image_pipe/cache/key.ex` uses the same candidate list instead of raw `Accept`, so candidate normalization is the cache boundary.
- Docs mention automatic output in `docs/operational_notes.md`, `docs/imgproxy_path_api.md`, `docs/cache.md`, and `docs/imgproxy_support_matrix.md`.

## Files And Tests

- Code: `lib/image_pipe/output/negotiation.ex`
- Tests: `test/image_pipe/output_negotiation_test.exs`
- Tests: `test/image_pipe/output_negotiation_property_test.exs`
- Tests: `test/image_pipe/output_policy_test.exs`
- Tests: `test/image_pipe/cache/key_test.exs`
- Tests: `test/image_pipe/request/http_cache_test.exs`
- Tests: `test/image_pipe/plug_test.exs`
- Docs if they claim wildcard-only modern negotiation: `docs/operational_notes.md`, `docs/imgproxy_path_api.md`, `docs/cache.md`, `docs/imgproxy_support_matrix.md`

## TDD Steps

- [ ] Add failing negotiation examples for `nil`, `""`, whitespace-only, bare `*/*`, parameterized `*/*;q=1`, `*/*; q=0.8`, and non-image-plus-wildcard `application/json,*/*;q=1` returning `[]`; keep `image/*`, explicit AVIF/WebP, mixed `image/webp,*/*`, q-values, and exact exclusions covered.
- [ ] Update the negotiation property oracle so global wildcard doesn't make AVIF/WebP acceptable without an exact or `image/*` signal.
- [ ] Add policy assertions that missing, empty, and wildcard-only `Accept` produce no modern candidates but still return automatic `Vary: Accept`.
- [ ] Add cache key assertions that missing, empty, and wildcard-only automatic requests normalize to the same output key data and hash, without raw `Accept`.
- [ ] Add request HTTP cache assertions that missing, empty, and wildcard-only automatic requests produce the same generated ETag and don't include raw `Accept` material.
- [ ] Add or adjust request-level tests showing omitted-format JPEG output for missing, empty, and wildcard-only `Accept`, plus explicit AVIF/WebP still selecting AVIF/WebP and preserving `Vary: Accept`.
- [ ] Run the focused tests and confirm the new tests fail for the existing wildcard behavior.
- [ ] Change only `ImagePipe.Output.Negotiation` so global wildcard-only headers are non-informative for modern candidates.
- [ ] Re-run the focused tests until green.
- [ ] Update docs only where current text claims old wildcard behavior.

## Verification Commands

- `mise exec -- mix test test/image_pipe/output_negotiation_test.exs test/image_pipe/output_negotiation_property_test.exs test/image_pipe/output_policy_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/request/http_cache_test.exs test/image_pipe/plug_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`
- `mise exec -- mix compile --warnings-as-errors`
