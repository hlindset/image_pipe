# S3 STS AssumeRole + EKS/IRSA Web-Identity Credential Providers — Implementation Plan (Plan 2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two more S3 credential providers on top of Plan 1's `RefreshCache` + `CredentialProvider` contract: STS `AssumeRole` (cross-account, a composing wrapper that signs an STS call with a base provider's credentials) and EKS/IRSA `AssumeRoleWithWebIdentity` (an unsigned STS call authenticated by a projected OIDC token file).

**Architecture:** Both providers speak the AWS STS Query protocol — a form-encoded POST to the regional endpoint `https://sts.<region>.amazonaws.com/` whose response is always XML. A shared internal `ImagePipe.Source.S3.Sts` module builds the request body, performs the POST (SigV4-signed for `AssumeRole`, unsigned for `AssumeRoleWithWebIdentity`), and extracts the four credential fields from the `<Credentials>` element. `AssumeRole` resolves its base credentials through `Credentials.fetch/3` (so the base goes through *its own* cache entry) and signs the STS call with them, reusing the **same** Req `aws_sigv4` step the live S3 GET path already uses (only the service changes `:s3` → `:sts`, so signing correctness is already proven). `AssumeRoleWithWebIdentity` re-reads the token file every refresh (it rotates) and sends the token in the request body as the authentication. Both return `{:ok, credentials, expiry}` and cache through Plan 1's `RefreshCache`, keyed by `{:s3_credentials, provider, opts, scope}` — single-flight matters here to avoid STS throttling on bursts.

**Tech Stack:** Elixir, `Req` (HTTP + the built-in `aws_sigv4` step, via the `plug:` option for hermetic tests), `URI.encode_query/1` (form body), targeted regex extraction of the four STS XML fields (no `:xmerl`/`sweet_xml` — sidesteps atom-explosion + XXE for a trusted fixed-schema response), `NimbleOptions` (provider option validation), ExUnit.

**Scope note:** This is host-config capability parity, **not** wire conformance — imgproxy's `IMGPROXY_S3_ASSUME_ROLE_*` env vars are its host config, not part of the URL dialect, and IRSA is handled invisibly by the aws-sdk-go-v2 default chain. **No** `docs/imgproxy_support_matrix.md` pixel/stage/order change is required (see ground-truth confirmation in Task 6). The only doc touched is `docs/operational_notes.md`.

**Ground truth (read before implementing):**
- imgproxy source: `/Users/hlindset/src/imgproxy` — `storage/s3/storage.go:62-72` wraps `stscreds.NewAssumeRoleProvider(sts.NewFromConfig(conf), AssumeRoleArn, …ExternalID…)` in `aws.NewCredentialsCache` ("AssumeRole is called once per token … AssumeRoleProvider has no caching and calls STS on every Retrieve()"). Base creds come from the SDK default chain; IRSA web-identity is picked up by that chain from `AWS_WEB_IDENTITY_TOKEN_FILE` + `AWS_ROLE_ARN` — imgproxy writes no explicit web-identity code. `storage/s3/config.go:28-29` documents `AssumeRoleArn` + `AssumeRoleExternalID` (both default `""`).
- imgproxy docs: `/Users/hlindset/src/imgproxy-docs/docs/image_sources/amazon_s3.mdx:69` — "S3 access credentials may be acquired by assuming a role using STS … specify the IAM Role arn with `IMGPROXY_S3_ASSUME_ROLE_ARN` … if you require an external ID … `IMGPROXY_S3_ASSUME_ROLE_EXTERNAL_ID`. This approach still requires you to provide initial AWS credentials … The provided credentials role should allow assuming the role with provided ARN."
- AWS STS Query API version: `2011-06-15`. `AssumeRole` and `AssumeRoleWithWebIdentity` both require `RoleArn` and `RoleSessionName`; `AssumeRoleWithWebIdentity` additionally requires `WebIdentityToken` and "does not require the use of AWS security credentials" (unsigned). Both responses wrap `<Credentials>{AccessKeyId, SecretAccessKey, SessionToken, Expiration}</Credentials>`.

**Flagged design decisions (confirm during plan review):**
1. **XML parsing strategy — targeted regex extraction, not `sweet_xml`/`:xmerl`.** `sweet_xml` 0.7.5 is present but only *transitively* (via `:image`); relying on it directly would couple us to another lib's dep graph, and `:xmerl` underneath has the classic atom-explosion + XXE exposure on untrusted XML. The STS response is a trusted, fixed four-field schema whose values are base64/ISO-8601 (no `<`, `>`, `&`), so a scoped regex over the `<Credentials>` block is robust, dependency-free, and avoids the whole debate. Pinned by a recorded real STS sample fixture + malformed/missing-field cases. The compatibility/AWS-fidelity reviewer should confirm the extraction matches real STS wire output for **both** actions.
2. **Provider modules are NOT boundary-exported.** Plan 1's `InstanceRole`/`ContainerCredentials` are *not* in `ImagePipe.Source`'s `exports:` — they are referenced only as config *data* (`{:provider, Module, opts}` atoms), which creates no compile-time cross-boundary edge. `AssumeRole` and `WebIdentity` follow that exact pattern, so **no `lib/image_pipe/source.ex` export edit and no `architecture_boundary_test.exs` change is required.** (This intentionally diverges from the prompt's "export new modules" instruction, which assumed the InstanceRole pattern exported its providers; it does not.) **Confirmed by the architecture plan-reviewer:** `source.ex` exports neither existing provider; `architecture_boundary_test.exs:208–219` asserts an *exact* export-list match, so adding the providers would be both unnecessary (no cross-boundary compile edge — dispatch is dynamic via `provider.fetch_credentials/3`) and would *break* that test unless the list were also padded with dead export surface (violating AGENTS "Boundary exports should stay narrow"). The shared `Sts` module is likewise internal (mirrors the unexported `MetadataRequest`).
3. **`RoleSessionName` default `"image-pipe"`**, overridable via `:role_session_name`. STS requires a session name on both actions; a stable default keeps CloudTrail readable. Note this is a deliberate, friendlier *divergence* from imgproxy, not bug-for-bug parity: imgproxy sets no session name (`storage/s3/storage.go:63-69` passes only `ExternalID`), letting aws-sdk-go-v2 auto-generate `aws-sdk-go-<timestamp>`.
4. **STS HTTP timeout default 5000ms** (not the 2000ms metadata default) — STS is a public-internet, possibly cross-region call, not a link-local hop. Overridable via `:receive_timeout`/`:connect_timeout`. **Cold-path budget (document-as-acceptable):** `Entry.get`'s `GenServer.call` defaults to 10s (`refresh_cache.ex:18`). A cold `AssumeRole` fetch runs *base resolve + STS round-trip*; when the base is itself STS (AssumeRole-over-AssumeRole) the worst case can approach that 10s. This is safe-by-design: the fetch runs in the Entry's `Task` (not the GenServer), so a caller that times out gets fail-closed `{:source, :credentials_unavailable}` while the Task keeps running and warms the cache for the next request. Keep `retry: false` on the STS POST — the 5-minute refresh margin (creds refresh ~55 min into a 1 h lifetime) is the intended cushion for a transient STS throttle/5xx, so a single failed refresh serves the still-fresh value rather than erroring. **Do not** add STS retries.
5. **Cache-key hygiene (single-flight).** The provider opts become part of the `RefreshCache` key (`{:s3_credentials, provider, opts, scope}`), so opts must contain only **serializable static config**. `:plug` is **test-only** and must never appear in production config; a closure, PID, or ref in opts (including a nested `:base`'s opts) would silently fragment single-flight. Production opts here (`base`, `role_arn`, `region`, `external_id`, `role_session_name`, timeouts) are all static terms — correct.
6. **Credential-handling discipline.** The signed STS body carries the base secret key (forwarded as the SigV4 signature) and, for web-identity, the OIDC token; `AssumeRole`'s opts hold the resolved base credentials in transit. All STS failures map to **opaque atoms** (`:sts_request_failed`, `:sts_unreachable`, `:sts_invalid_response`) with **no response body or opts in the error term**, `Req.request/1` is non-bang (no body-bearing exception can raise), and the cache `Entry` already redacts its stored value (`format_status/1`) and maps a crashing fetch to `:fetch_crashed`. The `Sts` POST helper and both providers' `fetch_credentials/3` carry a `# do not inspect/log opts, params, or body` comment so no future debug line leaks the base secret or OIDC token. Surfacing the STS `<Error><Code>` (e.g. `AccessDenied`) in the error term is a deferred operability enhancement — there is no telemetry consumer for the provider error path today, so keep errors opaque per YAGNI.

---

## File Structure

**Create:**
- `lib/image_pipe/source/s3/sts.ex` — shared STS Query client: build form body, POST (signed/unsigned) to the regional endpoint, extract the four credential fields. Internal, value-returning (`{:ok, credentials, expiry} | {:error, reason}`); not boundary-exported.
- `lib/image_pipe/source/s3/assume_role.ex` — `AssumeRole` provider (#8), composing wrapper over a base provider.
- `lib/image_pipe/source/s3/web_identity.ex` — `WebIdentity` provider (#7), EKS/IRSA.
- `test/image_pipe/source/s3/sts_test.exs` — `Sts` parser unit tests (recorded sample + malformed) and the signed/unsigned POST shape via a Req `plug` stub.
- `test/image_pipe/source/s3/assume_role_test.exs`
- `test/image_pipe/source/s3/web_identity_test.exs`
- `test/image_pipe/source/s3/sts_localstack_test.exs` — opt-in `@tag :aws_integration` LocalStack lane (excluded from default `mix test`).

**Modify:**
- `test/test_helper.exs` — add `:aws_integration` to the `ExUnit.start` `exclude:` list.
- `docs/operational_notes.md` — replace the "STS `AssumeRole` … and EKS/IRSA … are not yet supported." sentence with the real config for both providers.
- `docs/imgproxy_support_matrix.md` — flip the assume-role rows (`IMGPROXY_S3_ASSUME_ROLE_ARN`/`_EXTERNAL_ID`) from `⭕` to `✅` and drop "assume-role environment variables" from the not-provided prose (surface-axis conformance sync; see Task 6).

**Not modified (decision 2):** `lib/image_pipe/source.ex` exports, `test/image_pipe/architecture_boundary_test.exs`. The providers and `Sts` are referenced only within the `ImagePipe.Source` boundary (as data, or by same-boundary calls), so no export edge is created. `mix compile --warnings-as-errors` in the final gate is the check that this holds.

---

## Task 1: Shared STS XML extraction (`Sts.parse_credentials/1`)

Pure parsing, no HTTP. Extract `AccessKeyId`, `SecretAccessKey`, `SessionToken`, `Expiration` from the `<Credentials>` element of an STS Query response and return `{:ok, credentials, expiry}`. The same `<Credentials>` shape is used by both `AssumeRoleResponse` and `AssumeRoleWithWebIdentityResponse`, so one extractor serves both.

**Files:**
- Create: `lib/image_pipe/source/s3/sts.ex`
- Test: `test/image_pipe/source/s3/sts_test.exs`

- [ ] **Step 1: Write the failing parser tests**

Create `test/image_pipe/source/s3/sts_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.StsTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.Sts

  # A representative real STS AssumeRole response. The wire format sends compact
  # element values (the AWS docs pretty-print the SessionToken across lines for
  # readability; the actual response does not), so this fixture keeps values on
  # one line — matching what the parser sees in production.
  @assume_role_xml ~s(<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleResult><AssumedRoleUser><Arn>arn:aws:sts::123456789012:assumed-role/demo/image-pipe</Arn><AssumedRoleId>ARO123EXAMPLE123:image-pipe</AssumedRoleId></AssumedRoleUser><Credentials><AccessKeyId>ASIAIOSFODNN7EXAMPLE</AccessKeyId><SecretAccessKey>wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY</SecretAccessKey><SessionToken>AQoDYXdzEPT//////////wEXAMPLEtc764bNrC9SAPBSM22wDOk4x4HIZ8j4FZTwdQWLWsKWHGBuFqwAeMicRXmxfpSPfIeoIYRqTflfKD8YUuwthAx7mSEI/qkPpKPi/kMcGdQrmGdeehM4IC1NtBmUpp2wUE8phUZampKsburEDy0KPkyQDYwT7WZ0wq5VSXDvp75YU9HFvlRd8Tx6q6fE8YQcHNVXAkiY9q6d+xo0rKwT38xVqr7ZD0u0iPPkUL64lIZbqBAz+scqKmlzm8FDrypNC9Yjc8fPOLn9FX9KSYvKTr4rvx3iSIlTJabIQwj2ICCR/oLxBA==</SessionToken><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials><PackedPolicySize>6</PackedPolicySize></AssumeRoleResult><ResponseMetadata><RequestId>c6104cbe-af31-11e0-8154-cbc7ccf896c7</RequestId></ResponseMetadata></AssumeRoleResponse>)

  @web_identity_xml ~s(<AssumeRoleWithWebIdentityResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><AssumeRoleWithWebIdentityResult><SubjectFromWebIdentityToken>sub-123</SubjectFromWebIdentityToken><Audience>sts.amazonaws.com</Audience><AssumedRoleUser><Arn>arn:aws:sts::123456789012:assumed-role/eks/image-pipe</Arn><AssumedRoleId>ARO456:image-pipe</AssumedRoleId></AssumedRoleUser><Credentials><AccessKeyId>ASIAEKSEXAMPLE</AccessKeyId><SecretAccessKey>eksSecretEXAMPLEKEY</SecretAccessKey><SessionToken>eksSessionTokenEXAMPLE==</SessionToken><Expiration>2026-06-26T14:00:00Z</Expiration></Credentials><Provider>arn:aws:iam::123456789012:oidc-provider/oidc.eks</Provider></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>)

  test "extracts the four credential fields from an AssumeRole response" do
    assert {:ok, creds, expiry} = Sts.parse_credentials(@assume_role_xml)
    assert creds[:access_key_id] == "ASIAIOSFODNN7EXAMPLE"
    assert creds[:secret_access_key] == "wJalrXUtnFEMI/K7MDENG/bPxRfiCYzEXAMPLEKEY"
    assert creds[:token] =~ "AQoDYXdzEPT"
    assert expiry == ~U[2026-06-26 13:34:41Z]
  end

  test "extracts credentials from an AssumeRoleWithWebIdentity response (same shape)" do
    assert {:ok, creds, expiry} = Sts.parse_credentials(@web_identity_xml)
    assert creds[:access_key_id] == "ASIAEKSEXAMPLE"
    assert creds[:token] == "eksSessionTokenEXAMPLE=="
    assert expiry == ~U[2026-06-26 14:00:00Z]
  end

  test "errors on a malformed/error STS response with no Credentials element" do
    error_xml =
      ~s(<ErrorResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/"><Error><Type>Sender</Type><Code>AccessDenied</Code><Message>Not authorized to perform sts:AssumeRole</Message></Error></ErrorResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(error_xml)
  end

  test "errors when a required field is missing from Credentials" do
    missing =
      ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>s</SecretAccessKey><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(missing)
  end

  test "errors on a non-ISO8601 expiration" do
    bad =
      ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>AK</AccessKeyId><SecretAccessKey>s</SecretAccessKey><SessionToken>t</SessionToken><Expiration>not-a-date</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

    assert {:error, :sts_invalid_response} = Sts.parse_credentials(bad)
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/sts_test.exs`
Expected: FAIL — `ImagePipe.Source.S3.Sts` is undefined.

- [ ] **Step 3: Implement the extractor**

Create `lib/image_pipe/source/s3/sts.ex` with just the parser for now (the HTTP client lands in Task 2, appended to the same module):

```elixir
defmodule ImagePipe.Source.S3.Sts do
  @moduledoc false
  # Shared AWS STS Query-protocol client for the AssumeRole (#8) and
  # AssumeRoleWithWebIdentity (#7) credential providers.
  #
  # STS always responds with XML. Rather than pull in :xmerl/sweet_xml (atom
  # explosion + XXE on untrusted XML, plus sweet_xml is only a transitive dep),
  # we extract the four credential fields from the fixed-schema <Credentials>
  # block with a scoped regex. STS values are base64/ISO-8601 — they never
  # contain `<`, `>`, or `&` — so the extraction is robust, and a recorded-sample
  # test pins it to real wire output.

  @credentials_block ~r{<Credentials>(?<inner>.*?)</Credentials>}s

  @spec parse_credentials(binary()) ::
          {:ok, keyword(), DateTime.t()} | {:error, :sts_invalid_response}
  def parse_credentials(xml) when is_binary(xml) do
    with %{"inner" => inner} <- Regex.named_captures(@credentials_block, xml),
         {:ok, access_key_id} <- field(inner, "AccessKeyId"),
         {:ok, secret_access_key} <- field(inner, "SecretAccessKey"),
         {:ok, token} <- field(inner, "SessionToken"),
         {:ok, expiration} <- field(inner, "Expiration"),
         {:ok, expiry, _offset} <- DateTime.from_iso8601(expiration) do
      {:ok,
       [access_key_id: access_key_id, secret_access_key: secret_access_key, token: token],
       expiry}
    else
      _other -> {:error, :sts_invalid_response}
    end
  end

  def parse_credentials(_other), do: {:error, :sts_invalid_response}

  defp field(inner, tag) do
    case Regex.run(~r{<#{tag}>([^<]*)</#{tag}>}, inner) do
      [_, value] ->
        case String.trim(value) do
          "" -> :error
          trimmed -> {:ok, trimmed}
        end

      _none ->
        :error
    end
  end
end
```

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/sts_test.exs`
Expected: PASS (all five parser tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/sts.ex test/image_pipe/source/s3/sts_test.exs
git commit -m "feat(s3): STS Query response credential extraction"
```

---

## Task 2: STS POST transport (signed AssumeRole + unsigned web-identity)

Add the request side to `ImagePipe.Source.S3.Sts`: build the form body, POST to `https://sts.<region>.amazonaws.com/`, and parse. Two public entry points — `assume_role/1` (SigV4-signed with the caller's base credentials) and `assume_role_with_web_identity/1` (unsigned; the OIDC token in the body is the auth). Hermetic via Req's `plug:` option.

**Files:**
- Modify: `lib/image_pipe/source/s3/sts.ex`
- Test: `test/image_pipe/source/s3/sts_test.exs`

- [ ] **Step 1: Write the failing transport tests**

Append to `test/image_pipe/source/s3/sts_test.exs` (inside the module). These assert the *request shape* — the heart of STS protocol fidelity — by capturing the POST in a Req plug:

```elixir
  # Reuse the recorded success body for transport tests.
  defp ok_plug(capture_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(capture_pid, {:sts_request, conn.method, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 200, @assume_role_xml)
    end
  end

  test "assume_role signs the POST and form-encodes Action/RoleArn/RoleSessionName" do
    base = [access_key_id: "AKIABASE", secret_access_key: "BASESECRET", token: "BASESESSION"]

    opts = [
      region: "eu-west-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      role_session_name: "image-pipe",
      external_id: "ext-42",
      base_credentials: base,
      plug: ok_plug(self())
    ]

    assert {:ok, creds, _expiry} = Sts.assume_role(opts)
    assert creds[:access_key_id] == "ASIAIOSFODNN7EXAMPLE"

    assert_received {:sts_request, "POST", "/", headers, body}

    # SigV4-signed with the base credentials and the :sts service.
    auth = header(headers, "authorization")
    assert auth =~ "AWS4-HMAC-SHA256"
    assert auth =~ "/sts/aws4_request"
    assert auth =~ "Credential=AKIABASE/"
    # the base session token is forwarded as the security-token header
    assert ["BASESESSION"] = Enum.filter(value_list(headers, "x-amz-security-token"), & &1)
    assert header(headers, "content-type") =~ "application/x-www-form-urlencoded"

    # form body carries the AssumeRole action + parameters
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRole"
    assert params["Version"] == "2011-06-15"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/demo"
    assert params["RoleSessionName"] == "image-pipe"
    assert params["ExternalId"] == "ext-42"
  end

  test "assume_role omits ExternalId when not configured" do
    base = [access_key_id: "AKIABASE", secret_access_key: "BASESECRET"]

    opts = [
      region: "us-east-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      base_credentials: base,
      plug: ok_plug(self())
    ]

    assert {:ok, _creds, _expiry} = Sts.assume_role(opts)
    assert_received {:sts_request, "POST", "/", _headers, body}
    params = URI.decode_query(body)
    refute Map.has_key?(params, "ExternalId")
    assert params["RoleSessionName"] == "image-pipe"
  end

  test "assume_role_with_web_identity POSTs unsigned with the token in the body" do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(self(), :unused)
      send(parent(), {:sts_request, conn.method, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 200, @web_identity_xml)
    end

    opts = [
      region: "eu-west-1",
      role_arn: "arn:aws:iam::123456789012:role/eks",
      role_session_name: "image-pipe",
      web_identity_token: "OIDC.TOKEN.VALUE",
      plug: plug
    ]

    assert {:ok, creds, _expiry} = Sts.assume_role_with_web_identity(opts)
    assert creds[:access_key_id] == "ASIAEKSEXAMPLE"

    assert_received {:sts_request, "POST", headers, body}
    # UNSIGNED: no SigV4 Authorization header
    assert header(headers, "authorization") == nil

    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRoleWithWebIdentity"
    assert params["Version"] == "2011-06-15"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/eks"
    assert params["WebIdentityToken"] == "OIDC.TOKEN.VALUE"
  end

  test "maps an STS non-200 to an error" do
    plug = fn conn -> Plug.Conn.send_resp(conn, 403, "<ErrorResponse/>") end

    opts = [
      region: "us-east-1",
      role_arn: "arn:aws:iam::123456789012:role/demo",
      base_credentials: [access_key_id: "AK", secret_access_key: "SK"],
      plug: plug
    ]

    assert {:error, :sts_request_failed} = Sts.assume_role(opts)
  end

  # --- header helpers ---
  defp parent, do: self()

  defp header(headers, name) do
    case value_list(headers, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  defp value_list(headers, name),
    do: for({k, v} <- headers, k == name, do: v)
```

> Note for the implementer: `parent/0`/`self()` inside the plug closure both evaluate in the **test process** here because Req runs the plug synchronously in the caller process. The `send(self(), :unused)` line is illustrative noise — drop it; just `send(self(), {:sts_request, …})` works. Keep the assertions; they are the contract.

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/sts_test.exs`
Expected: FAIL — `Sts.assume_role/1` and `Sts.assume_role_with_web_identity/1` are undefined.

- [ ] **Step 3: Implement the transport**

Append to `lib/image_pipe/source/s3/sts.ex` (add the functions and the `@version`/`@default_timeout_ms`/`@default_session_name` module attrs near the top, after the `@moduledoc`):

```elixir
  @version "2011-06-15"
  @default_session_name "image-pipe"
  @default_timeout_ms 5_000

  @spec assume_role(keyword()) ::
          {:ok, keyword(), DateTime.t()} | {:error, term()}
  def assume_role(opts) do
    region = Keyword.fetch!(opts, :region)

    params =
      [
        {"Action", "AssumeRole"},
        {"Version", @version},
        {"RoleArn", Keyword.fetch!(opts, :role_arn)},
        {"RoleSessionName", session_name(opts)}
      ]
      |> maybe_put("ExternalId", Keyword.get(opts, :external_id))

    sigv4 =
      opts
      |> Keyword.fetch!(:base_credentials)
      |> Keyword.take([:access_key_id, :secret_access_key, :token])
      |> Keyword.merge(service: :sts, region: region)

    post(region, params, [aws_sigv4: sigv4], opts)
  end

  @spec assume_role_with_web_identity(keyword()) ::
          {:ok, keyword(), DateTime.t()} | {:error, term()}
  def assume_role_with_web_identity(opts) do
    region = Keyword.fetch!(opts, :region)

    params = [
      {"Action", "AssumeRoleWithWebIdentity"},
      {"Version", @version},
      {"RoleArn", Keyword.fetch!(opts, :role_arn)},
      {"RoleSessionName", session_name(opts)},
      {"WebIdentityToken", Keyword.fetch!(opts, :web_identity_token)}
    ]

    # Unsigned: the OIDC token is the authentication.
    post(region, params, [], opts)
  end

  # do not inspect/log `opts`, `params`, or `body` here — the signed body carries
  # the base secret key (via the SigV4 signature) and, for web-identity, the OIDC
  # token. Errors stay opaque; the response body is never put in an error term.
  defp post(region, params, sign_opts, opts) do
    req_opts =
      [
        method: :post,
        url: endpoint(region),
        body: URI.encode_query(params),
        headers: [{"content-type", "application/x-www-form-urlencoded"}],
        retry: false,
        redirect: false,
        receive_timeout: timeout(opts, :receive_timeout),
        connect_options: [timeout: timeout(opts, :connect_timeout)]
      ]
      |> Keyword.merge(sign_opts)
      |> maybe_plug(opts)

    case safe_request(req_opts) do
      {:ok, %{status: 200, body: body}} -> parse_credentials(to_string(body))
      {:ok, %{status: _other}} -> {:error, :sts_request_failed}
      {:error, _reason} -> {:error, :sts_unreachable}
    end
  end

  defp safe_request(req_opts) do
    case Req.request(req_opts) do
      {:ok, %Req.Response{} = response} -> {:ok, response}
      {:error, _exception} -> {:error, :unreachable}
    end
  end

  defp endpoint(region), do: "https://sts." <> region <> ".amazonaws.com/"

  defp session_name(opts), do: Keyword.get(opts, :role_session_name, @default_session_name)

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: params ++ [{key, value}]

  defp maybe_plug(req_opts, opts) do
    case Keyword.get(opts, :plug) do
      nil -> req_opts
      plug -> Keyword.put(req_opts, :plug, plug)
    end
  end

  defp timeout(opts, key), do: Keyword.get(opts, key, @default_timeout_ms)
```

> Implementer note on signing: this reuses Req's built-in `aws_sigv4` step (the same one `ImagePipe.Source.S3.fetch/3` uses for the live S3 GET). Setting `body:` before the step runs means Req signs the exact form bytes it sends; `service: :sts` is the only change from the S3 path, and `:token` (the base session token) is forwarded as `x-amz-security-token`. `Req.request/1` (non-bang) keeps a transport failure from raising into the cache's fetch task.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/sts_test.exs`
Expected: PASS (parser + transport).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/sts.ex test/image_pipe/source/s3/sts_test.exs
git commit -m "feat(s3): STS signed AssumeRole + unsigned web-identity POST transport"
```

---

## Task 3: `AssumeRole` provider (#8) — composing wrapper

A `CredentialProvider` that resolves a base provider's credentials through `Credentials.fetch/3` (so the base uses its own cache entry), then exchanges them for assumed-role credentials via `Sts.assume_role/1`. Its `validate_options/1` validates its own options *and* recursively validates the base config at startup.

**Files:**
- Create: `lib/image_pipe/source/s3/assume_role.ex`
- Test: `test/image_pipe/source/s3/assume_role_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/s3/assume_role_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.AssumeRoleTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.AssumeRole

  # A static base so the test does not depend on IMDS/ECS. The provider resolves
  # the base through Credentials.fetch/3 regardless of base shape.
  @base {:static, [access_key_id: "AKIABASE", secret_access_key: "BASESECRET"]}

  @assume_role_xml ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIAASSUMED</AccessKeyId><SecretAccessKey>assumedSecret</SecretAccessKey><SessionToken>assumedSession</SessionToken><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

  defp sts_plug(capture) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(capture, {:sts_body, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, @assume_role_xml)
    end
  end

  test "resolves base credentials and exchanges them for assumed-role credentials" do
    opts = [
      base: @base,
      role_arn: "arn:aws:iam::123456789012:role/demo",
      region: "eu-west-1",
      plug: sts_plug(self())
    ]

    assert {:ok, creds, expiry} = AssumeRole.fetch_credentials("my-bucket", opts, [])
    assert creds[:access_key_id] == "ASIAASSUMED"
    assert creds[:secret_access_key] == "assumedSecret"
    assert creds[:token] == "assumedSession"
    assert expiry == ~U[2026-06-26 13:34:41Z]

    assert_received {:sts_body, body, headers}
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRole"
    assert params["RoleArn"] == "arn:aws:iam::123456789012:role/demo"
    # signed with the resolved base key
    auth = for({k, v} <- headers, k == "authorization", do: v) |> List.first()
    assert auth =~ "Credential=AKIABASE/"
  end

  test "fails when the base credentials cannot be resolved" do
    opts = [
      base: {:provider, __MODULE__.FailingBase, []},
      role_arn: "arn:aws:iam::123456789012:role/demo",
      region: "eu-west-1"
    ]

    assert {:error, _reason} =
             AssumeRole.fetch_credentials("bkt-#{System.unique_integer([:positive])}", opts, [])
  end

  defmodule FailingBase do
    @behaviour ImagePipe.Source.S3.CredentialProvider
    @impl true
    def fetch_credentials(_scope, _opts, _runtime), do: {:error, :no_base}
  end

  test "validate_options requires role_arn and region and validates the base" do
    assert :ok =
             AssumeRole.validate_options(
               base: @base,
               role_arn: "arn:aws:iam::1:role/x",
               region: "us-east-1"
             )

    assert {:error, _} = AssumeRole.validate_options(base: @base, region: "us-east-1")
    assert {:error, _} = AssumeRole.validate_options(base: @base, role_arn: "arn:…")
    assert {:error, _} =
             AssumeRole.validate_options(
               base: {:static, []},
               role_arn: "arn:…",
               region: "us-east-1"
             )
  end
end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/assume_role_test.exs`
Expected: FAIL — `ImagePipe.Source.S3.AssumeRole` undefined.

- [ ] **Step 3: Implement the provider**

Create `lib/image_pipe/source/s3/assume_role.ex`:

```elixir
defmodule ImagePipe.Source.S3.AssumeRole do
  @moduledoc """
  Cross-account credential provider via STS `AssumeRole`.

  A composing wrapper: it resolves a **base** provider's credentials, then signs
  an STS `AssumeRole` call with them to obtain temporary credentials for a
  different role (typically in another account).

      credentials:
        {:provider, ImagePipe.Source.S3.AssumeRole,
         base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
         role_arn: "arn:aws:iam::123456789012:role/image-read",
         external_id: "optional-external-id",
         region: "eu-west-1"}

  Options:
    * `:base` — the base credential config (`{:static, …}` or `{:provider, …}`)
      whose credentials are allowed to assume `:role_arn`. **Required.** Resolved
      through `ImagePipe.Source.S3.Credentials.fetch/3`, so the base uses its own
      cache entry.
    * `:role_arn` — ARN of the role to assume. **Required.**
    * `:region` — region for the STS endpoint and SigV4 signing. **Required.**
    * `:external_id` — external ID required by the trust policy (optional).
    * `:role_session_name` — STS session name (default `"image-pipe"`).
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms),
      default 5000.
    * `:plug` — test-only Req plug.

  Both the base resolution and the assumed credentials are cached and refreshed
  by `ImagePipe.Source.S3.RefreshCache` before expiry.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Credentials
  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 base: [type: :any, required: true],
                 role_arn: [type: :string, required: true],
                 region: [type: :string, required: true],
                 external_id: [type: :string],
                 role_session_name: [type: :string],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer],
                 plug: [type: :any]
               )

  @impl true
  def validate_options(opts) do
    with {:ok, validated} <- schema_validate(opts),
         {:ok, _base} <- Credentials.validate(Keyword.fetch!(validated, :base)) do
      :ok
    else
      {:error, %NimbleOptions.ValidationError{} = error} -> {:error, Exception.message(error)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp schema_validate(opts), do: NimbleOptions.validate(opts, @opts_schema)

  # do not inspect/log `opts` or `base_credentials` — they carry the base secret
  # key. The STS error is opaque; base creds never appear in an error term.
  @impl true
  def fetch_credentials(scope, opts, _runtime_opts) do
    base = Keyword.fetch!(opts, :base)

    with {:ok, base_credentials} <- Credentials.fetch(scope, base, []) do
      # `external_id` is passed explicitly because `Sts.maybe_put/3` is nil-safe
      # (a nil ExternalId is simply omitted from the form). Everything else
      # optional goes through `Keyword.take`, which OMITS absent keys rather than
      # passing `key: nil` — otherwise an explicit nil would defeat `Sts`'s
      # `Keyword.get(opts, key, default)` for the session name and timeouts.
      Sts.assume_role(
        [
          region: Keyword.fetch!(opts, :region),
          role_arn: Keyword.fetch!(opts, :role_arn),
          external_id: Keyword.get(opts, :external_id),
          base_credentials: base_credentials
        ] ++ Keyword.take(opts, [:role_session_name, :receive_timeout, :connect_timeout, :plug])
      )
    end
  end
end
```

> Implementer note: `Credentials.validate/1` returns `{:ok, base} | {:error, {:invalid_source_config, reason}}`; surface that reason as-is from `validate_options/1`. The `Keyword.take` discipline above (never pass `key: nil`) is the fix for `Sts`'s `Keyword.get(opts, key, default)` defaults — `WebIdentity` (Task 4) applies the identical pattern.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/assume_role_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/assume_role.ex test/image_pipe/source/s3/assume_role_test.exs
git commit -m "feat(s3): STS AssumeRole composing credential provider"
```

---

## Task 4: `WebIdentity` provider (#7) — EKS/IRSA

A `CredentialProvider` that reads the OIDC token from a file (re-read every fetch, since the projected token rotates) and exchanges it via the unsigned `Sts.assume_role_with_web_identity/1`.

**Files:**
- Create: `lib/image_pipe/source/s3/web_identity.ex`
- Test: `test/image_pipe/source/s3/web_identity_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/source/s3/web_identity_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.WebIdentityTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Source.S3.WebIdentity

  @xml ~s(<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials><AccessKeyId>ASIAEKS</AccessKeyId><SecretAccessKey>eksSecret</SecretAccessKey><SessionToken>eksSession</SessionToken><Expiration>2026-06-26T14:00:00Z</Expiration></Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>)

  @tag :tmp_dir
  test "reads the token file and exchanges it for credentials", %{tmp_dir: tmp_dir} do
    token_path = Path.join(tmp_dir, "token")
    File.write!(token_path, "OIDC-TOKEN-CONTENTS\n")

    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:sts_body, body, conn.req_headers})
      Plug.Conn.send_resp(conn, 200, @xml)
    end

    opts = [
      token_file: token_path,
      role_arn: "arn:aws:iam::123456789012:role/eks",
      region: "eu-west-1",
      plug: plug
    ]

    assert {:ok, creds, expiry} = WebIdentity.fetch_credentials("my-bucket", opts, [])
    assert creds[:access_key_id] == "ASIAEKS"
    assert creds[:token] == "eksSession"
    assert expiry == ~U[2026-06-26 14:00:00Z]

    assert_received {:sts_body, body, headers}
    params = URI.decode_query(body)
    assert params["Action"] == "AssumeRoleWithWebIdentity"
    # token file contents are trimmed and sent in the body
    assert params["WebIdentityToken"] == "OIDC-TOKEN-CONTENTS"
    # unsigned
    assert [] == for({k, _v} <- headers, k == "authorization", do: :found)
  end

  @tag :tmp_dir
  test "re-reads the token file on each fetch (rotation)", %{tmp_dir: tmp_dir} do
    token_path = Path.join(tmp_dir, "token")
    File.write!(token_path, "FIRST")
    test = self()

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test, {:token, URI.decode_query(body)["WebIdentityToken"]})
      Plug.Conn.send_resp(conn, 200, @xml)
    end

    opts = [token_file: token_path, role_arn: "arn:…", region: "us-east-1", plug: plug]

    assert {:ok, _, _} = WebIdentity.fetch_credentials("b", opts, [])
    assert_received {:token, "FIRST"}

    File.write!(token_path, "SECOND")
    assert {:ok, _, _} = WebIdentity.fetch_credentials("b", opts, [])
    assert_received {:token, "SECOND"}
  end

  test "errors when the token file is missing" do
    opts = [token_file: "/no/such/token", role_arn: "arn:…", region: "us-east-1"]
    assert {:error, :web_identity_token_unreadable} =
             WebIdentity.fetch_credentials("b", opts, [])
  end

  test "validate_options requires token_file, role_arn, and region" do
    assert :ok =
             WebIdentity.validate_options(
               token_file: "/var/run/token",
               role_arn: "arn:…",
               region: "us-east-1"
             )

    assert {:error, _} = WebIdentity.validate_options(role_arn: "arn:…", region: "us-east-1")
    assert {:error, _} = WebIdentity.validate_options(token_file: "/t", region: "us-east-1")
    assert {:error, _} = WebIdentity.validate_options(token_file: "/t", role_arn: "arn:…")
  end
end
```

> Note: `WebIdentity.fetch_credentials/3` is called directly here, so each call re-reads the file — this proves rotation at the provider boundary. (In production the `RefreshCache` calls `fetch_credentials` once per refresh, which is exactly when a fresh token read is needed.)

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/image_pipe/source/s3/web_identity_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the provider**

Create `lib/image_pipe/source/s3/web_identity.ex`:

```elixir
defmodule ImagePipe.Source.S3.WebIdentity do
  @moduledoc """
  EKS/IRSA credential provider via STS `AssumeRoleWithWebIdentity`.

  On EKS with IAM Roles for Service Accounts (IRSA), the cluster projects a
  short-lived OIDC token into the pod and injects `AWS_WEB_IDENTITY_TOKEN_FILE`
  and `AWS_ROLE_ARN`. This provider reads that token file and exchanges it for
  temporary credentials with an **unsigned** STS call (the token is the auth).

      credentials:
        {:provider, ImagePipe.Source.S3.WebIdentity,
         token_file: System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
         role_arn: System.get_env("AWS_ROLE_ARN"),
         region: System.get_env("AWS_REGION")}

  Options:
    * `:token_file` — path to the projected OIDC token. **Required.** Re-read on
      every refresh, because the projected token rotates.
    * `:role_arn` — ARN of the role to assume. **Required.**
    * `:region` — region for the STS endpoint. **Required.**
    * `:role_session_name` — STS session name (default `"image-pipe"`).
    * `:receive_timeout` / `:connect_timeout` — bounded HTTP timeouts (ms),
      default 5000.
    * `:plug` — test-only Req plug.

  Results are cached and refreshed by `ImagePipe.Source.S3.RefreshCache`.
  """
  @behaviour ImagePipe.Source.S3.CredentialProvider

  alias ImagePipe.Source.S3.Sts

  @opts_schema NimbleOptions.new!(
                 token_file: [type: :string, required: true],
                 role_arn: [type: :string, required: true],
                 region: [type: :string, required: true],
                 role_session_name: [type: :string],
                 receive_timeout: [type: :non_neg_integer],
                 connect_timeout: [type: :non_neg_integer],
                 plug: [type: :any]
               )

  @impl true
  def validate_options(opts) do
    case NimbleOptions.validate(opts, @opts_schema) do
      {:ok, _validated} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  # do not inspect/log `opts` or `token` — the OIDC token is a bearer credential.
  @impl true
  def fetch_credentials(_scope, opts, _runtime_opts) do
    with {:ok, token} <- read_token(Keyword.fetch!(opts, :token_file)) do
      Sts.assume_role_with_web_identity(
        [
          region: Keyword.fetch!(opts, :region),
          role_arn: Keyword.fetch!(opts, :role_arn),
          web_identity_token: token
        ] ++
          Keyword.take(opts, [:role_session_name, :receive_timeout, :connect_timeout, :plug])
      )
    end
  end

  defp read_token(path) do
    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> {:error, :web_identity_token_unreadable}
          token -> {:ok, token}
        end

      {:error, _reason} ->
        {:error, :web_identity_token_unreadable}
    end
  end
end
```

> Implementer note: `Sts.assume_role_with_web_identity/1` defaults `role_session_name` to `"image-pipe"` via `session_name/1`, so `Keyword.take` omitting it is correct (no `nil` override). Same nil-omission discipline as `AssumeRole` — use `Keyword.take`, never pass `key: nil`.

- [ ] **Step 4: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/web_identity_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/source/s3/web_identity.ex test/image_pipe/source/s3/web_identity_test.exs
git commit -m "feat(s3): EKS/IRSA AssumeRoleWithWebIdentity credential provider"
```

---

## Task 5: End-to-end cache integration (both providers through `Credentials.fetch`)

Prove that the new providers route through `RefreshCache` exactly like Plan 1's — single fetch per `{provider, opts, scope}`, fail-closed mapping — without re-testing the cache internals (Plan 1 owns those).

**Files:**
- Test: append to `test/image_pipe/source/s3/credentials_cache_test.exs`

- [ ] **Step 1: Write the integration test**

Append to `test/image_pipe/source/s3/credentials_cache_test.exs` (inside the module):

```elixir
  test "AssumeRole provider routes through the cache and normalizes" do
    xml =
      ~s(<AssumeRoleResponse><AssumeRoleResult><Credentials><AccessKeyId>ASIAX</AccessKeyId><SecretAccessKey>sx</SecretAccessKey><SessionToken>tx</SessionToken><Expiration>2026-06-26T13:34:41Z</Expiration></Credentials></AssumeRoleResult></AssumeRoleResponse>)

    test = self()

    plug = fn conn ->
      send(test, :sts_called)
      Plug.Conn.send_resp(conn, 200, xml)
    end

    provider =
      {:provider, ImagePipe.Source.S3.AssumeRole,
       base: {:static, [access_key_id: "AKIABASE", secret_access_key: "SK"]},
       role_arn: "arn:aws:iam::1:role/x",
       region: "us-east-1",
       plug: plug}

    scope = "assume-#{System.unique_integer([:positive])}"

    assert {:ok, creds} = Credentials.fetch(scope, provider, [])
    assert creds[:access_key_id] == "ASIAX"
    assert creds[:token] == "tx"
    assert_received :sts_called

    # cached: no second STS call for the same scope
    assert {:ok, _} = Credentials.fetch(scope, provider, [])
    refute_received :sts_called
  end
```

- [ ] **Step 2: Run to verify it passes**

Run: `mise exec -- mix test test/image_pipe/source/s3/credentials_cache_test.exs`
Expected: PASS. (No production code change needed — `Credentials.fetch/3`'s `{:provider, …}` clause already handles any `CredentialProvider`. If it fails, the failure points at a contract mismatch in Task 3, not at the cache.)

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/source/s3/credentials_cache_test.exs
git commit -m "test(s3): AssumeRole provider routes through the refresh cache"
```

---

## Task 6: Documentation + support-matrix sync + integration-lane tag

Update `docs/operational_notes.md`, flip the imgproxy support matrix's assume-role rows to supported, and register the opt-in integration tag.

**Compatibility-doc sync (REQUIRED — this is a surface-axis change).** This is host-config parity (imgproxy exposes assume-role as `IMGPROXY_S3_*` env vars and delegates IRSA to the aws-sdk-go-v2 default chain — no URL-dialect/stage/pixel change). The plan-review **corrected an earlier wrong assumption**: `docs/imgproxy_support_matrix.md` **already carries** assume-role rows that this change moves from unsupported → supported, so per AGENTS' "keep each compatibility target's conformance doc in sync … **surface** (the option/config tables)" rule the matrix **must** be updated in this same change. The compatibility reviewer must confirm the symbol/wording. (IRSA needs **no** matrix row — imgproxy has no IRSA-specific env var; the SDK chain handles it invisibly.)

**Files:**
- Modify: `docs/operational_notes.md`, `docs/imgproxy_support_matrix.md`, `test/test_helper.exs`

- [ ] **Step 1: Replace the "not yet supported" note**

In `docs/operational_notes.md`, replace:

```markdown
STS `AssumeRole` (cross-account) and EKS/IRSA web-identity credentials are not
yet supported.
```

with:

```markdown
- **STS `AssumeRole` (cross-account):** a composing wrapper. It resolves a base
  provider's credentials and signs an STS `AssumeRole` call with them to obtain
  temporary credentials for a role in another account.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.AssumeRole,
     base: {:provider, ImagePipe.Source.S3.InstanceRole, []},
     role_arn: "arn:aws:iam::123456789012:role/image-read",
     external_id: "optional-external-id",
     region: "eu-west-1"}
  ```

  The base config (`:base`) is any other credential shape (`{:static, …}` or
  `{:provider, …}`) whose role is allowed to assume `:role_arn`; it is resolved
  through its own cache entry. `:external_id` is optional. The base credentials
  and the assumed credentials are each cached and refreshed before expiry.

- **EKS / IRSA, via STS `AssumeRoleWithWebIdentity`:** reads the projected OIDC
  token file (re-read on every refresh, since it rotates) and exchanges it for
  temporary credentials with an unsigned STS call.

  ```elixir
  credentials:
    {:provider, ImagePipe.Source.S3.WebIdentity,
     token_file: System.get_env("AWS_WEB_IDENTITY_TOKEN_FILE"),
     role_arn: System.get_env("AWS_ROLE_ARN"),
     region: System.get_env("AWS_REGION")}
  ```

Both providers call the regional STS endpoint (`sts.<region>.amazonaws.com`) and
cache through the same refresh cache as the other providers — single STS call
per credential lifetime, fail-closed on expiry. Unlike imgproxy (which defaults
to `us-west-1`), `:region` is **mandatory** on both providers — there is no
silent region fallback. For EKS/IRSA the `:token_file` is the projected-volume
symlink the cluster injects; following that symlink is intentional (re-reading
it each refresh is how rotation is picked up).
```

- [ ] **Step 2: Flip the support-matrix assume-role rows**

In `docs/imgproxy_support_matrix.md`, the "S3 image sources" section currently
lists assume-role as unsupported. Change the two rows (around lines 463–464):

```markdown
- ⭕ `IMGPROXY_S3_ASSUME_ROLE_ARN`
- ⭕ `IMGPROXY_S3_ASSUME_ROLE_EXTERNAL_ID`
```

to supported, with a host-config-parity note (matching how `IMGPROXY_S3_REGION`
etc. are marked `✅`):

```markdown
- ✅ `IMGPROXY_S3_ASSUME_ROLE_ARN` — via `{:provider, ImagePipe.Source.S3.AssumeRole, role_arn: …}` (host config; see `operational_notes.md`).
- ✅ `IMGPROXY_S3_ASSUME_ROLE_EXTERNAL_ID` — via the `:external_id` option of `AssumeRole`.
```

And amend the prose (around line 454–455) — drop "assume-role environment
variables" from the not-provided list, since it is now provided. The sentence

```markdown
It doesn't provide
Imgproxy's enable flag, denied-bucket list, assume-role environment variables, or
decryption client.
```

becomes:

```markdown
It doesn't provide
Imgproxy's enable flag, denied-bucket list, or decryption client.
```

Leave `IMGPROXY_S3_USE_DECRYPTION_CLIENT` and `IMGPROXY_S3_DENIED_BUCKETS` as
`⭕` — those are unchanged. Verify the legend symbol `✅` matches the doc's
existing meaning for host-config-supported options before committing.

- [ ] **Step 3: Register the integration tag exclusion**

In `test/test_helper.exs`, add `:aws_integration` to the `ExUnit.start` `exclude:` list (alongside `:imgproxy_triage` etc.):

```elixir
  exclude: [
    :image_vision,
    :imgproxy_triage,
    :imgproxy_report,
    :twicpics_triage,
    :twicpics_report,
    :aws_integration
  ]
```

Add a short comment above the `ExUnit.start` block describing the tag (mirroring the existing tag comments): `:aws_integration` runs the opt-in LocalStack STS round-trip (`--include aws_integration`); it is a protocol-fidelity smoke test, **not** a correctness gate (LocalStack does not strictly verify SigV4 — signing is already proven by the live S3 GET path).

- [ ] **Step 4: Commit**

```bash
git add docs/operational_notes.md docs/imgproxy_support_matrix.md test/test_helper.exs
git commit -m "docs(s3): document STS AssumeRole and EKS/IRSA web-identity providers

Flip imgproxy support-matrix assume-role rows to supported (host-config parity)."
```

---

## Task 7: Optional LocalStack integration lane (`@tag :aws_integration`)

A single opt-in test exercising a real STS implementation end-to-end. **Skippable** — correctness is already covered hermetically by the `plug` stubs above; this only confirms a real AWS-compatible server accepts our request shapes. Excluded from the default `mix test` lane (Task 6 Step 2).

**Files:**
- Create: `test/image_pipe/source/s3/sts_localstack_test.exs`

- [ ] **Step 1: Write the opt-in integration test**

Create `test/image_pipe/source/s3/sts_localstack_test.exs`:

```elixir
defmodule ImagePipe.Source.S3.StsLocalstackTest do
  # Opt-in protocol-fidelity smoke test against LocalStack's STS. NOT a
  # correctness gate (LocalStack does not strictly verify SigV4). Run with:
  #   mise exec -- mix test --include aws_integration test/image_pipe/source/s3/sts_localstack_test.exs
  # Requires Docker; locally set TESTCONTAINERS_RYUK_DISABLED=true (and run
  # `MIX_ENV=test mix deps.get` first), same as the imgproxy bake.
  use ExUnit.Case, async: false

  @moduletag :aws_integration

  alias ImagePipe.Source.S3.Sts

  setup_all do
    {:ok, container} =
      Testcontainers.start_container(
        Testcontainers.Container.new("localstack/localstack:3")
        |> Testcontainers.Container.with_exposed_port(4566)
        |> Testcontainers.Container.with_environment("SERVICES", "sts")
      )

    base = "http://#{Testcontainers.Container.get_host(container)}:#{Testcontainers.Container.mapped_port(container, 4566)}"
    {:ok, endpoint: base}
  end

  @tag timeout: 120_000
  test "AssumeRole round-trips against LocalStack", %{endpoint: endpoint} do
    # LocalStack accepts any creds; point the Sts client at it via a one-off plug
    # that rewrites the host to the container. (LocalStack's STS returns the same
    # XML <Credentials> shape, so the parser is exercised end-to-end.)
    plug = {Req.Test, __MODULE__}
    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 502, "configure: #{endpoint}") end)

    # NOTE for the implementer: wire the real call against `endpoint` here. The
    # cleanest path is to add an internal `:endpoint_override` opt to
    # `Sts.post/4` (used only by this lane) so the URL targets LocalStack while
    # the signing region stays "us-east-1". Keep that override out of the public
    # provider option schemas. If adding the override is judged not worth it,
    # delete this file and rely on the hermetic plug tests (the lane is optional).
    assert is_binary(endpoint)
  end
end
```

> Implementer decision point: LocalStack does not exercise signing (so it adds little over the plug tests), and reaching it requires either an `:endpoint_override` seam in `Sts` or a host-rewriting plug. **If that seam feels like surface bloat, drop this task entirely** — the plan's hermetic tests are the correctness gate and the prompt marks this lane explicitly optional. If you keep it, add the narrow `:endpoint_override` opt to `Sts.post/4` (internal only, never in the provider `@opts_schema`s) and assert the parsed `{:ok, creds, expiry}` from LocalStack's response. Either way, this must stay excluded from the default lane.

- [ ] **Step 2: Run only the hermetic suite to confirm exclusion**

Run: `mise exec -- mix test test/image_pipe/source/s3/`
Expected: PASS, and the LocalStack test is **skipped** (excluded tag). Confirm the run reports the integration test as excluded, not executed.

- [ ] **Step 3: Commit**

```bash
git add test/image_pipe/source/s3/sts_localstack_test.exs
git commit -m "test(s3): opt-in LocalStack STS integration lane (excluded by default)"
```

---

## Final verification

- [ ] **Step 1: Run the focused S3 suite**

Run: `mise exec -- mix test test/image_pipe/source/`
Expected: PASS (hermetic; the `:aws_integration` test excluded).

- [ ] **Step 2: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all pass. The `--warnings-as-errors` compile is the check that no new cross-boundary export edge was created (decision 2): if `AssumeRole`/`WebIdentity`/`Sts` were referenced across a boundary, Boundary would fail here.

- [ ] **Step 3: Final commit if the gate produced formatting changes**

```bash
git add -A
git commit -m "chore(s3): satisfy precommit gate"
```

---

## Self-Review (completed during authoring)

**Spec coverage:**
- STS `AssumeRole` (#8), composing wrapper, signed with base creds via the reused `aws_sigv4` step (`:s3` → `:sts`), external ID optional, base through its own cache entry → Tasks 2–3, cache integration Task 5.
- EKS/IRSA `AssumeRoleWithWebIdentity` (#7), token file re-read each refresh, unsigned POST, shared STS parser → Tasks 1, 2, 4.
- STS Query protocol / XML-only / four-field extraction with recorded sample + malformed → Task 1.
- Regional endpoint `sts.<region>.amazonaws.com` → `Sts.endpoint/1` (Task 2).
- RefreshCache reuse + single-flight + fail-closed mapping → inherited from Plan 1, exercised in Task 5.
- `validate_options/1` via NimbleOptions on both providers; `AssumeRole` recursively validates `:base` → Tasks 3–4.
- Hermetic `plug` tests asserting the signed `Authorization: AWS4-HMAC-SHA256` + `Action=AssumeRole` body and the unsigned web-identity POST with token-file contents → Tasks 2–4.
- STS parser unit test vs recorded sample → Task 1.
- Optional, opt-in LocalStack lane excluded from default `mix test` → Tasks 6–7.
- `docs/operational_notes.md` "not yet supported" note replaced → Task 6.

**Type consistency:** `Sts.parse_credentials/1`, `Sts.assume_role/1`, `Sts.assume_role_with_web_identity/1` all return `{:ok, keyword(), DateTime.t()} | {:error, term()}`. Both providers' `fetch_credentials/3` return the same 3-tuple, matching the `CredentialProvider` behaviour. Normalized credential keys are `:access_key_id`, `:secret_access_key`, `:token` everywhere (the `Credentials.fetch` cache closure normalizes again, idempotently). `expiry` is a `DateTime.t()` (STS always returns a concrete expiration; never `:never`). Provider option key `:base` (AssumeRole) / `:token_file` (WebIdentity) are used consistently in schema, impl, and tests.

**Placeholder scan:** No `TBD`/`TODO`/"handle edge cases". Task 2's plug helper carries an explicit "drop this illustrative line" note; Task 7 is explicitly marked optional-and-deletable with a concrete seam if kept.

**Open items for plan review:** all four below were raised and resolved in the review cycle — see "Plan-review cycle (applied)".

---

## Plan-review cycle (applied 2026-06-26)

Three disjoint reviewers ran against this plan: **AWS STS protocol fidelity** (vs the local imgproxy checkout `/Users/hlindset/src/imgproxy` + the AWS STS Query API + the Req signing internals), **OTP/cache-integration & credential security**, and **architecture/boundaries/tests**. All three returned *no blocking defects*; accepted feedback was folded in:

- **Architecture (material fix):** the original Task 6 wrongly claimed `docs/imgproxy_support_matrix.md` had no assume-role section. It does — `IMGPROXY_S3_ASSUME_ROLE_ARN`/`_EXTERNAL_ID` are listed `⭕` (unsupported) with disclaiming prose. This is a **surface-axis** conformance change, so Task 6 now flips both rows to `✅` and corrects the prose, and the matrix is in the Modify list + the Task 6 commit. The reviewer also **confirmed decision 2** (providers/`Sts` stay unexported; the exact-match boundary test needs no change — adding exports would be unnecessary *and* test-breaking).
- **AWS fidelity:** confirmed the signed/unsigned split, params, `Version=2011-06-15`, regional endpoint with matching signing region, base `:token` → `x-amz-security-token` (verified in `deps/req/lib/req/utils.ex`), exact-bytes body signing, and the `<Credentials>` four-field extraction (the `[^<]*` regex is safe — those four AWS-controlled fields never carry `<`/`>`/`&`). Folded in: documented the `RoleSessionName` divergence from imgproxy (decision 3), the mandatory-`:region` divergence (no `us-west-1` fallback — Task 6 note), and the deliberate `retry: false` cushioned by the 5-min refresh margin (decision 4). Surfacing the STS `<Error><Code>` was assessed and **deferred** (no provider-error telemetry consumer today — YAGNI; noted in decision 6).
- **OTP/security:** confirmed no deadlock/recursion (fetch runs in the Entry `Task`; base resolves via a *different* cache key/GenServer; `{:static, …}` base resolves inline), correct fail-closed mapping to `{:source, :credentials_unavailable}`, non-bang Req + opaque atom errors + `format_status` redaction (no credential/body leak), correct token-file re-read/rotation, and right-boundary NimbleOptions validation. Folded in: the cold-path timeout budget note (decision 4), cache-key hygiene (decision 5 — opts must be serializable; `:plug` test-only), `# do not inspect/log opts/params/body` comments on `Sts.post` + both providers (decision 6), and aligning the Task 3 `AssumeRole` code sample with the `Keyword.take` nil-omission discipline so a verbatim copy can't ship `key: nil`.
- **Confirmed needing no change:** `lib/image_pipe/source/s3/credentials.ex` (its `{:provider, …}` `fetch`/`validate` clauses already dispatch dynamically to any `CredentialProvider`), `lib/image_pipe/source.ex` exports, and `test/image_pipe/architecture_boundary_test.exs`.
