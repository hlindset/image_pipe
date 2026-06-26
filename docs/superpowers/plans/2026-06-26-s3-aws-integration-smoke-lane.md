# S3 AWS Integration Smoke Lane (Plan 3) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the opt-in, Docker-tagged `:aws_integration` lane so it covers IMDS (`InstanceRole`) and STS (`AssumeRole` + `AssumeRoleWithWebIdentity`) end-to-end against real, independent mock servers, provisioned self-containedly via `testcontainers`.

**Architecture:** Pure test-tooling — **no `lib/` changes**. A new `AWS_INTEGRATION` env flag adds the `testcontainers` dep (mirroring `IMGPROXY_DIFF`). A compile-guarded test-support helper owns the container plumbing (start LocalStack STS + `amazon-ec2-metadata-mock`, return mapped base URLs, register cleanup). Two compile-guarded, `:aws_integration`-tagged test files drive the providers through their existing seams (`InstanceRole`'s `:base_url`, `Sts`'s `:endpoint_override`). The lane is a **protocol-fidelity smoke test, not a correctness gate** (LocalStack does not verify SigV4; signing is proven by the live S3 GET path).

**Tech Stack:** Elixir, ExUnit, `testcontainers` (`~> 1.14`, test-only, env-gated), `Req` (readiness polling + the providers' own HTTP), Docker (LocalStack, amazon-ec2-metadata-mock).

**Design doc:** `docs/superpowers/specs/2026-06-26-s3-aws-integration-smoke-lane-design.md`

---

## Background the implementer needs

- **Both seams already exist** — confirm before editing `lib/` (you should NOT need to):
  - `lib/image_pipe/source/s3/sts.ex:71` — `url: Keyword.get(opts, :endpoint_override) || endpoint(region)`. Pass `:endpoint_override` (full URL) to point STS at a container.
  - `lib/image_pipe/source/s3/instance_role.ex` — `:base_url` option (default `"http://169.254.169.254"`). Pass `:base_url` to point IMDS at a container. The provider always does IMDSv2 token-PUT first, then the role-list GET, then the creds GET.
- **The `:aws_integration` tag is already excluded** in `test/test_helper.exs` (`exclude:` list). No change needed there.
- **testcontainers is NOT a normal dep** — it is added only when `IMGPROXY_DIFF` (today) is set. `mix.exs` deps fn lives around `mix.exs:183-189`. The established compile pattern for code that uses it is a module-top `if Code.ensure_loaded?(Testcontainers) do … end` guard (see `test/support/mix/tasks/imgproxy.gen_fixtures.ex:1`).
- **Container readiness pattern** (mirror, do not reinvent) — `imgproxy.gen_fixtures.ex:155-168` polls an HTTP health path with a bounded `Process.sleep(500)` loop. In ExUnit this is the **accepted exception** to the "no `Process.sleep`" test guideline: it waits on an *external Docker container* becoming reachable, not on an in-VM process — there is no monitor/`:sys.get_state` alternative for "is the container's HTTP server up yet". Keep the loop bounded and only in the container helper.
- **Ryuk** (testcontainers' reaper) fails locally; runs require `TESTCONTAINERS_RYUK_DISABLED=true`. Because Ryuk is disabled, the helper MUST stop its containers explicitly via `on_exit`.
- **Test-support namespace convention:** existing support module is `ImagePipe.SourceTest.CredentialProvider` at `test/support/image_pipe/source_test/credential_provider.ex`. Follow it: the new helper is `ImagePipe.SourceTest.S3.IntegrationContainers` at `test/support/image_pipe/source_test/s3/integration_containers.ex`.

---

## File Structure

**Modify:**
- `mix.exs` — generalize the testcontainers dep gate to `IMGPROXY_DIFF` **or** `AWS_INTEGRATION` (add the dep once; no duplicate).
- `test/image_pipe/source/s3/sts_localstack_test.exs` — rewrite from env-driven (`STS_LOCALSTACK_ENDPOINT`) to testcontainers-managed LocalStack via the shared helper.

**Create:**
- `test/support/image_pipe/source_test/s3/integration_containers.ex` — compile-guarded shared helper: `ensure_started/0`, `start_localstack_sts/0`, `start_ec2_metadata_mock/0`.
- `test/image_pipe/source/s3/instance_role_imds_test.exs` — new IMDS round-trip against `amazon-ec2-metadata-mock`.

**Not touched:** any `lib/` file, `docs/imgproxy_support_matrix.md`, `test/test_helper.exs`, CI, boundaries/telemetry.

---

## Task 1: Generalize the testcontainers dep gate (`mix.exs`)

Add `testcontainers` when either `IMGPROXY_DIFF` or `AWS_INTEGRATION` is set, deduped.

**Files:**
- Modify: `mix.exs` (the deps fn, around lines 183-189)

- [ ] **Step 1: Replace the `imgproxy_diff_deps` block**

Find (around `mix.exs:183`):

```elixir
    imgproxy_diff_deps =
      if System.get_env("IMGPROXY_DIFF") in ["1", "true"] do
        [{:testcontainers, "~> 1.14", only: :test}]
      else
        []
      end

    base ++ ml_test_deps ++ imgproxy_diff_deps
```

Replace with:

```elixir
    # `testcontainers` provisions Docker for two opt-in lanes: the imgproxy
    # differential bake (`IMGPROXY_DIFF`) and the AWS credential integration
    # smoke lane (`AWS_INTEGRATION`). Add it once when either is set so a
    # both-set run does not double-list the dep.
    testcontainers_deps =
      if System.get_env("IMGPROXY_DIFF") in ["1", "true"] or
           System.get_env("AWS_INTEGRATION") in ["1", "true"] do
        [{:testcontainers, "~> 1.14", only: :test}]
      else
        []
      end

    base ++ ml_test_deps ++ testcontainers_deps
```

- [ ] **Step 2: Verify the dep is declared only under the flag**

Use `mix deps.tree`, NOT `mix deps | grep` — `mix.lock` already carries a
`testcontainers` entry from the imgproxy lane, so a raw `grep` against the lock
or `mix deps` can report a non-zero count even when the dep is not *declared*.
`deps.tree` lists the **declared** dependency graph and ignores stale lock
entries:

Run: `mise exec -- mix deps.tree | grep -c testcontainers`
Expected: `0` (no `AWS_INTEGRATION`/`IMGPROXY_DIFF` → dep not declared).

Run: `AWS_INTEGRATION=1 mise exec -- mix deps.get` then
`AWS_INTEGRATION=1 mise exec -- mix deps.tree | grep -c testcontainers`
Expected: `≥1` (dep now declared and resolved). `deps.get` does not need Docker
or the Ryuk env (only running containers do), so this step is safe.

> The authoritative "absent by default" signal is the **compile guard** in Task 2
> Step 2 (the helper module is simply not defined when the dep is absent); this
> `deps.tree` check just confirms the declaration gate.

- [ ] **Step 3: Commit**

```bash
git add mix.exs mix.lock
git commit -m "build(test): gate testcontainers on AWS_INTEGRATION as well as IMGPROXY_DIFF"
```

> Note: `mix.lock` may gain a `testcontainers` entry from `deps.get`; commit it — it pins the opt-in dep deterministically (same as the imgproxy lane). If `deps.get` left `mix.lock` unchanged, just commit `mix.exs`.

---

## Task 2: Shared container helper (`IntegrationContainers`)

Compile-guarded test-support module that owns all `testcontainers` API use: idempotent manager start, plus one start-function per mock server returning its mapped base URL and registering `on_exit` cleanup.

**Files:**
- Create: `test/support/image_pipe/source_test/s3/integration_containers.ex`

This helper has **no standalone unit test** — it is pure container plumbing only meaningful with Docker, and is exercised end-to-end by Tasks 3 and 4. (Per the test guidelines, do not write a test that merely asserts the module/functions exist.)

- [ ] **Step 1: Create the helper**

Create `test/support/image_pipe/source_test/s3/integration_containers.ex`:

```elixir
if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.SourceTest.S3.IntegrationContainers do
    @moduledoc """
    Shared `testcontainers` plumbing for the opt-in `:aws_integration` smoke lane.

    Compiled only when the `testcontainers` dep is present (added by
    `AWS_INTEGRATION=1`/`IMGPROXY_DIFF=1`); a plain `mix test` skips this module
    entirely, so the integration lane cannot run on the default lane.

    How to run the whole lane (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Ryuk (testcontainers' reaper) fails locally, so it must be disabled; because
    it is disabled, each `start_*` helper stops its container explicitly via
    `on_exit`.
    """

    alias Testcontainers.Container

    # Pinned mock-server images. LocalStack 3.x ships the STS service; the EC2
    # metadata mock speaks IMDSv2 (token PUT) by default and serves IAM
    # security-credentials from its built-in defaults. Tags are confirmed on the
    # first inline run (a wrong tag fails the pull immediately and visibly).
    @localstack_image "localstack/localstack:3"
    @localstack_port 4566
    @metadata_mock_image "public.ecr.aws/aws-ec2-metadata-mock/amazon-ec2-metadata-mock:v1.11.2"
    @metadata_mock_port 1338

    @doc """
    Idempotently start the testcontainers manager (its app deps + GenServer,
    which the app does not auto-start). Safe to call from every `setup_all`.
    """
    def ensure_started do
      {:ok, _} = Application.ensure_all_started(:testcontainers)

      case Testcontainers.start_link() do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    @doc """
    Start LocalStack with the STS service and return its mapped base URL
    (e.g. `"http://localhost:32811"`). Registers `on_exit` cleanup.
    """
    def start_localstack_sts do
      base_url =
        @localstack_image
        |> Container.new()
        |> Container.with_exposed_port(@localstack_port)
        |> Container.with_environment("SERVICES", "sts")
        |> start_and_map(@localstack_port)

      wait_until_ready!(base_url <> "/_localstack/health")
      base_url
    end

    @doc """
    Start `amazon-ec2-metadata-mock` and return its mapped base URL. Registers
    `on_exit` cleanup. The returned URL has no trailing slash — `InstanceRole`
    appends `/latest/...` to its `:base_url`.
    """
    def start_ec2_metadata_mock do
      base_url =
        @metadata_mock_image
        |> Container.new()
        |> Container.with_exposed_port(@metadata_mock_port)
        |> start_and_map(@metadata_mock_port)

      # The mock does not force IMDSv2 locally, so an unauthenticated GET is fine
      # for readiness; the provider still drives the token-PUT path under test.
      wait_until_ready!(base_url <> "/latest/meta-data/")
      base_url
    end

    defp start_and_map(container, port) do
      {:ok, started} = Testcontainers.start_container(container)
      # Load-bearing ordering: register cleanup IMMEDIATELY after the container
      # starts and BEFORE the caller's `wait_until_ready!` poll. With Ryuk
      # disabled there is no reaper backstop, so if readiness times out and
      # raises, this already-registered `on_exit` is what stops the container.
      # Do NOT move the readiness poll before this registration.
      ExUnit.Callbacks.on_exit(fn -> Testcontainers.stop_container(started.container_id) end)
      mapped = Container.mapped_port(started, port)
      "http://localhost:#{mapped}"
    end

    # Bounded HTTP readiness poll. This `Process.sleep` is the accepted exception
    # to the no-sleep test rule: it waits on an external Docker container's HTTP
    # server, not an in-VM process (no monitor alternative exists).
    defp wait_until_ready!(url, attempts \\ 60)

    defp wait_until_ready!(url, 0) do
      raise "integration container at #{url} did not become ready"
    end

    defp wait_until_ready!(url, attempts) do
      case Req.get(url, retry: false) do
        {:ok, %Req.Response{status: status}} when status < 500 ->
          :ok

        _other ->
          Process.sleep(500)
          wait_until_ready!(url, attempts - 1)
      end
    end
  end
end
```

- [ ] **Step 2: Verify it compiles under the flag and is absent without it**

Run (no flag): `mise exec -- mix compile --warnings-as-errors`
Expected: clean compile; the helper module is **not** defined (dep absent) — nothing to warn about.

Run (with flag, requires the dep from Task 1): `AWS_INTEGRATION=1 mise exec -- mix compile --warnings-as-errors`
Expected: clean compile; the helper module compiles.

- [ ] **Step 3: Commit**

```bash
git add test/support/image_pipe/source_test/s3/integration_containers.ex
git commit -m "test(s3): testcontainers helper for the AWS integration smoke lane"
```

---

## Task 3: Rewrite the STS lane onto testcontainers

Convert `sts_localstack_test.exs` from the `STS_LOCALSTACK_ENDPOINT` env gate to a `Code.ensure_loaded?`-guarded, container-managed lane, keeping the same two assertions. This is the reconciliation: both lane files now use one mechanism.

**Files:**
- Modify (full rewrite): `test/image_pipe/source/s3/sts_localstack_test.exs`

- [ ] **Step 1: Replace the file contents**

Overwrite `test/image_pipe/source/s3/sts_localstack_test.exs` with:

```elixir
if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.Source.S3.StsLocalstackTest do
    @moduledoc """
    Opt-in protocol-fidelity smoke test against a real LocalStack STS, provisioned
    self-containedly via testcontainers. NOT a correctness gate — LocalStack does
    not strictly verify SigV4 (signing is proven by the live S3 GET path); this
    only confirms a real AWS-compatible server accepts our `AssumeRole` /
    `AssumeRoleWithWebIdentity` request shapes and returns parseable XML.

    How to run (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Compiled only when `testcontainers` is present (`AWS_INTEGRATION`/`IMGPROXY_DIFF`)
    and tagged `:aws_integration` (excluded from the default lane), so a normal
    `mix test` never touches it.
    """
    use ExUnit.Case, async: false

    @moduletag :aws_integration

    alias ImagePipe.Source.S3.Sts
    alias ImagePipe.SourceTest.S3.IntegrationContainers

    setup_all do
      IntegrationContainers.ensure_started()
      endpoint = IntegrationContainers.start_localstack_sts() <> "/"
      %{endpoint: endpoint}
    end

    test "AssumeRole round-trips against LocalStack STS", %{endpoint: endpoint} do
      # LocalStack accepts any credentials and returns the standard STS XML
      # <Credentials> shape, exercising the real HTTP POST + XML parse path.
      # `:endpoint_override` targets the container; the signing region stays a
      # normal value.
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe",
                 base_credentials: [access_key_id: "test", secret_access_key: "test"],
                 endpoint_override: endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:secret_access_key])
      assert is_binary(creds[:token])
    end

    test "AssumeRoleWithWebIdentity round-trips against LocalStack STS", %{endpoint: endpoint} do
      assert {:ok, creds, %DateTime{}} =
               Sts.assume_role_with_web_identity(
                 region: "us-east-1",
                 role_arn: "arn:aws:iam::000000000000:role/image-pipe-eks",
                 web_identity_token: "localstack-accepts-anything",
                 endpoint_override: endpoint
               )

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:token])
    end
  end
end
```

- [ ] **Step 2: Verify it is NOT executed on the default lane**

Run: `mise exec -- mix test test/image_pipe/source/s3/sts_localstack_test.exs`
Expected: `0 tests` (or "no tests to run" / the file compiles to nothing — dep absent). The lane must not execute.

- [ ] **Step 3: Run it inline against a real container (environmental — needs Docker)**

Run:

```bash
AWS_INTEGRATION=1 mise exec -- mix deps.get
TESTCONTAINERS_RYUK_DISABLED=true AWS_INTEGRATION=1 \
  mise exec -- mix test --include aws_integration \
  test/image_pipe/source/s3/sts_localstack_test.exs
```

Expected: `2 tests, 0 failures` (LocalStack pulls on first run; allow time). If LocalStack's STS endpoint path differs, confirm `Sts` posts to `/` (it does) and that `_localstack/health` returns 200.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/source/s3/sts_localstack_test.exs
git commit -m "test(s3): provision LocalStack STS lane via testcontainers"
```

---

## Task 4: New IMDS lane (`amazon-ec2-metadata-mock`)

Add IMDS coverage: `InstanceRole` round-trips against the metadata mock, confirming the IMDSv2 token-PUT path against a real, independent server.

**Files:**
- Create: `test/image_pipe/source/s3/instance_role_imds_test.exs`

- [ ] **Step 1: Create the file**

Create `test/image_pipe/source/s3/instance_role_imds_test.exs`:

```elixir
if Code.ensure_loaded?(Testcontainers) do
  defmodule ImagePipe.Source.S3.InstanceRoleImdsTest do
    @moduledoc """
    Opt-in protocol-fidelity smoke test for `InstanceRole` against a real
    `amazon-ec2-metadata-mock`, provisioned via testcontainers. NOT a correctness
    gate (the IMDSv2 token/role/creds parse path is covered hermetically by the
    Req `:plug` unit tests); this confirms an independent IMDS implementation
    accepts our token-PUT-then-GET sequence and returns parseable credentials.

    How to run (from the repo root):

        AWS_INTEGRATION=1 mise exec -- mix deps.get
        TESTCONTAINERS_RYUK_DISABLED=true \\
          mise exec -- mix test --include aws_integration

    Compiled only when `testcontainers` is present and tagged `:aws_integration`
    (excluded from the default lane), so a normal `mix test` never touches it.
    """
    use ExUnit.Case, async: false

    @moduletag :aws_integration

    alias ImagePipe.Source.S3.InstanceRole
    alias ImagePipe.SourceTest.S3.IntegrationContainers

    setup_all do
      IntegrationContainers.ensure_started()
      base_url = IntegrationContainers.start_ec2_metadata_mock()
      %{base_url: base_url}
    end

    test "fetches temporary credentials via IMDSv2 from a real metadata mock", %{
      base_url: base_url
    } do
      # InstanceRole always does the IMDSv2 token PUT first, then the role-list
      # GET, then the creds GET — so a successful result implies the mock honored
      # the token PUT. The role name is read from the mock's listing endpoint
      # (not hardcoded), so this tolerates whatever default profile it serves.
      assert {:ok, creds, %DateTime{}} =
               InstanceRole.fetch_credentials("any-bucket", [base_url: base_url], [])

      assert is_binary(creds[:access_key_id])
      assert is_binary(creds[:secret_access_key])
      assert is_binary(creds[:token])
    end
  end
end
```

- [ ] **Step 2: Verify it is NOT executed on the default lane**

Run: `mise exec -- mix test test/image_pipe/source/s3/instance_role_imds_test.exs`
Expected: `0 tests` / no tests to run (dep absent → module not compiled).

- [ ] **Step 3: Run it inline against a real container (environmental — needs Docker)**

Run:

```bash
TESTCONTAINERS_RYUK_DISABLED=true AWS_INTEGRATION=1 \
  mise exec -- mix test --include aws_integration \
  test/image_pipe/source/s3/instance_role_imds_test.exs
```

Expected: `1 test, 0 failures`.

**Environmental fallback (only if the round-trip errors).** The error tag tells
you *which* part of the mock's default payload is the problem — diagnose by tag
before changing anything:
- `{:error, :imds_no_role}` — the mock is not serving the
  `iam/security-credentials/` **listing**. Configure IAM data via container env
  (below).
- `{:error, :imds_invalid_credentials}` — **the most likely failure**: the
  listing works but the credentials JSON fails `parse_credentials/1`, almost
  always because `Expiration` is not parseable by `DateTime.from_iso8601/1`
  (non-ISO8601 format) or `Code` ≠ `"Success"`. Override the IAM values (incl. a
  valid ISO8601 `Expiration`) via container env.
- `{:error, :imds_token_unavailable}` — the token PUT itself failed; check the
  image/port, not the IAM data.

To configure: `amazon-ec2-metadata-mock` reads `AEMM_`-prefixed overrides (and/or
a mounted config file); supply the IAM security-credentials values that way —
confirm the exact keys against the pinned image's `--help`/defaults. Add the
needed `Container.with_environment("AEMM_...", "...")` calls in
`start_ec2_metadata_mock/0` and re-run. Keep the test assertions unchanged (field
types, not values). Note the resolution in the commit message.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/source/s3/instance_role_imds_test.exs
git commit -m "test(s3): IMDSv2 instance-role lane via amazon-ec2-metadata-mock"
```

---

## Task 5: Full-lane verification + gate

Confirm the lane is excluded by default and green when opted in, and that the repo gate passes.

**Files:** none (verification only).

- [ ] **Step 1: Default lane excludes the integration tests**

Run: `mise run precommit`
Expected: green. The two integration files and the helper are **not compiled** (dep absent), so they neither run nor warn.

- [ ] **Step 2: Demonstrate the tag-excluded form (dep present, not opted in)**

Run: `AWS_INTEGRATION=1 mise exec -- mix test test/image_pipe/source/s3/`
Expected: the unit tests pass and the run reports the `:aws_integration` tests as **excluded** (compiled, but tag-excluded without `--include`). This is the literal "EXCLUDED" report; Step 1 is the "absent" form. Both prove non-execution on the default lane.

- [ ] **Step 3: Full lane green (environmental — needs Docker)**

Run:

```bash
TESTCONTAINERS_RYUK_DISABLED=true AWS_INTEGRATION=1 \
  mise exec -- mix test --include aws_integration \
  test/image_pipe/source/s3/sts_localstack_test.exs \
  test/image_pipe/source/s3/instance_role_imds_test.exs
```

Expected: `3 tests, 0 failures` (2 STS + 1 IMDS), both containers spun up and torn down.

- [ ] **Step 4: Final commit (only if Task 4's environmental fallback changed anything)**

If no further changes were needed, there is nothing to commit here — the lane is complete.

---

## Self-review checklist (done while writing — recorded for the reviewer)

- **Spec coverage:** dep gating (Task 1), shared helper (Task 2), STS reconciliation onto testcontainers (Task 3), IMDS coverage + IMDSv2 token PUT (Task 4), non-execution-by-default + how-to-run moduledocs + full-lane green (Tasks 3-5). ECS skip and "no `lib/` change" are honored throughout. ✔
- **Placeholder scan:** the only deferred item is the IMDS env fallback in Task 4, which is a concrete, conditional, fully-specified branch (not a TBD) — required because the mock's default IAM payload is environmental. ✔
- **Type/name consistency:** helper module `ImagePipe.SourceTest.S3.IntegrationContainers` with `ensure_started/0`, `start_localstack_sts/0`, `start_ec2_metadata_mock/0` is referenced identically in Tasks 3 and 4. `:endpoint_override` (STS) and `:base_url` (IMDS) match the real seams in `sts.ex`/`instance_role.ex`. ✔
```
