# S3 AWS Integration Smoke Lane (Plan 3) — Design

**Status:** Approved design, ready for implementation plan.

## Goal

Complete the opt-in, Docker-tagged `:aws_integration` lane so it covers **all**
S3 credential providers end-to-end against real, independent server
implementations — framed in-test as a **protocol-fidelity smoke test, NOT a
correctness gate**. Correctness is already covered hermetically by the Req
`:plug` stub tests, and signing correctness is proven by the live S3 GET path.
LocalStack notably does **not** strictly verify SigV4, so it cannot prove
signing; the lane only confirms that real, independent AWS-compatible servers
accept our request shapes and return parseable responses.

Coverage:
- **IMDS** (instance-role) via `amazon-ec2-metadata-mock` — confirms the mock
  speaks IMDSv2 (token PUT) and `InstanceRole` round-trips against it.
- **STS** (`AssumeRole` + `AssumeRoleWithWebIdentity`) via LocalStack STS — keeps
  the existing two assertions, re-sourced from a container.
- **ECS** container credentials: **skipped** — it is a trivial JSON endpoint, so
  a Req `:plug` already *is* the mock; a container adds nothing.

## Provisioning / gating decision (the central fork)

**Chosen: testcontainers-managed, self-contained (approach a).** The lane spins
up its own containers via `testcontainers` behind a dedicated `AWS_INTEGRATION`
env gate (mirroring how `IMGPROXY_DIFF` gates the same dep). `--include
aws_integration` is then fully self-contained — no host pre-provisioning.

This was chosen over the env-driven alternative (host brings up endpoints, lane
reads endpoint env vars) for **self-containment**, at the cost of a new dep gate
and rewriting the existing env-driven STS file to match. Both integration files
end up on the **same mechanism** (testcontainers), satisfying the "don't leave
two different mechanisms" constraint.

### Grounding (feasibility confirmed)

- `amazon-ec2-metadata-mock` listens on **port 1338**, has **IMDSv2 enabled by
  default** (responds to the token PUT; does not force v2-only locally — fine,
  because `InstanceRole` always goes token-first), and serves IAM
  security-credentials data with an `Expiration` from its default config. The
  exact image tag and the mock's default role name are environmental details to
  confirm on the first inline run; the test reads the role from the listing
  endpoint rather than hardcoding it, so it is tolerant of the default profile.
- LocalStack STS already works against the `:endpoint_override` seam (the
  existing file proves it); only the endpoint source changes (container mapped
  port instead of an env var).

## Architecture

**No production code changes.** Both seams already exist:
- `InstanceRole`'s `:base_url` option points IMDS at the container.
- `Sts`'s internal `:endpoint_override` seam points STS at the container.

The change is entirely test-tooling: a dep-gate generalization, a shared
testcontainers support helper, one rewritten test file, and one new test file.

### 1. Dependency gating (`mix.exs`)

Today `{:testcontainers, "~> 1.14", only: :test}` is added only under
`IMGPROXY_DIFF`. Generalize so it is added **once** when either `IMGPROXY_DIFF`
or a new `AWS_INTEGRATION` flag is set (deduped so both-set does not double-list
the dep). Matches the existing `System.get_env("X") in ["1", "true"]` idiom:

```elixir
needs_testcontainers? =
  System.get_env("IMGPROXY_DIFF") in ["1", "true"] or
    System.get_env("AWS_INTEGRATION") in ["1", "true"]

testcontainers_deps =
  if needs_testcontainers?, do: [{:testcontainers, "~> 1.14", only: :test}], else: []
```

### 2. Non-execution guarantee (two independent layers)

1. **Compile guard.** Each integration module (and the shared helper) is wrapped
   in `if Code.ensure_loaded?(Testcontainers) do … end`. On a plain `mix test`
   (dep absent) the modules **do not compile → zero tests exist**.
2. **Tag exclusion.** `@moduletag :aws_integration` is already in
   `test_helper.exs`'s `exclude:` list. Even when the dep *is* present (e.g. an
   `IMGPROXY_DIFF=1` run), the lane is **excluded** unless `--include
   aws_integration` is passed.

CI runs plain `mix test` with neither flag → modules never compile, never run.
**No `test_helper.exs` change and no CI change are required** (verify CI does not
set `AWS_INTEGRATION`).

> Note on "reported as EXCLUDED": under approach (a), a plain `mix test` shows
> the lane as **not compiled / absent** (not "N excluded"), because the dep is
> gone. The literal "N excluded" report appears only when the dep is present
> (e.g. `IMGPROXY_DIFF=1 mix test`). Both states prove non-execution on the
> default lane; the verification step demonstrates both.

### 3. Shared helper — `test/support/image_pipe/source/s3/integration_containers.ex`

Compile-guarded (`Code.ensure_loaded?(Testcontainers)`). Owns the testcontainers
API in one place so the test files stay focused on protocol assertions:

- `ensure_started/0` — idempotent: `Application.ensure_all_started(:testcontainers)`
  then `Testcontainers.start_link()`, tolerating `{:error, {:already_started, _}}`.
- `start_localstack_sts/0` — `Container.new(localstack image)` with
  `SERVICES=sts`, expose the LocalStack port, `start_container`, register
  `on_exit` to `stop_container`, return the mapped base URL.
- `start_ec2_metadata_mock/0` — same shape for `amazon-ec2-metadata-mock`
  (expose 1338), return the mapped base URL.

`on_exit` is registered from within the caller's `setup_all` (where these
helpers run), so cleanup is explicit and does not rely on Ryuk (disabled
locally).

### 4. The two test files

Both: `Code.ensure_loaded?`-guarded, `@moduletag :aws_integration`,
`use ExUnit.Case, async: false`, with a moduledoc documenting the run recipe.

**Rewrite** `test/image_pipe/source/s3/sts_localstack_test.exs`:
- Remove the `STS_LOCALSTACK_ENDPOINT` env gate.
- `setup_all` calls the helper to bring up LocalStack; passes the mapped URL as
  `:endpoint_override`.
- Keep the existing two assertions (`assume_role`, `assume_role_with_web_identity`).

**New** `test/image_pipe/source/s3/instance_role_imds_test.exs`:
- `setup_all` brings up `amazon-ec2-metadata-mock`.
- One test drives `InstanceRole.fetch_credentials("any-bucket", [base_url: url],
  [])` and asserts `{:ok, creds, %DateTime{}}` with binary `access_key_id`,
  `secret_access_key`, `token`. The IMDSv2 token PUT is implicitly confirmed
  (the provider always does token-first; the mock must accept it for the GETs to
  succeed). The role name comes from the listing endpoint, not a hardcode.

### 5. "How to run" (moduledoc, per the prompt)

Documented in both files (and the helper):

```
AWS_INTEGRATION=1 mise exec -- mix deps.get          # adds testcontainers
TESTCONTAINERS_RYUK_DISABLED=true \
  mise exec -- mix test --include aws_integration     # spins up its own containers
```

## Not touched

- Any `lib/` code (no production change — both seams pre-exist).
- `docs/imgproxy_support_matrix.md` (no surface/stage/pixel change; this is
  test tooling).
- Boundaries / `architecture_boundary_test.exs`, telemetry, Logger, OTel.
- `test_helper.exs` (`:aws_integration` already excluded) and CI.
- `docs/operational_notes.md` — left untouched; the test moduledocs are the
  documented home for "how to run" per the prompt.

## Testing / verification

- `mise run precommit` green.
- Plain `mise exec -- mix test`: the lane is **not executed** (modules absent,
  dep gone). Also demonstrate the tag-excluded form with the dep present.
- Inline `--include aws_integration` run goes **green against real containers**
  (environmental; run inline, not in a subagent), confirming the metadata mock's
  IMDSv2 token PUT and the LocalStack STS round-trips.

## Risks / open environmental items (resolve on first inline run)

- Exact `amazon-ec2-metadata-mock` image reference + tag and its default IAM
  profile shape (must include `Code:Success` + the four credential fields +
  ISO-8601 `Expiration`). Assertions stay tolerant (read role from listing;
  assert field types, not values).
- LocalStack image tag for the STS service.
- `TESTCONTAINERS_RYUK_DISABLED=true` required locally (same as the imgproxy
  bake); documented in the moduledocs.
