# Dialect-neutral CORS via host `allow_origin` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the IIIF "mount `ImagePipe.Parser.IIIF.CORS` ahead of `ImagePipe.Plug`" footgun with a flat, dialect-neutral `allow_origin` mount option and a neutral core CORS mechanism (before-send header decoration + always-answer OPTIONS).

**Architecture:** `allow_origin` is a validated flat option in `ImagePipe.Request.Options` (default `nil` = off). A neutral helper `ImagePipe.Response.CORS` registers a before-send hook that stamps `Access-Control-Allow-Origin` on every response when configured, and answers OPTIONS with `204 + Allow: GET, HEAD` (plus `Access-Control-Allow-Methods` when CORS is on). `ImagePipe.Plug` invokes it generically, naming no dialect. The IIIF parser is untouched; its `CORS` plug is deleted.

**Tech Stack:** Elixir, Plug, NimbleOptions, ExUnit, `Boundary`, `:telemetry`.

**Spec:** `docs/superpowers/specs/2026-06-28-neutral-cors-allow-origin-design.md`

---

## Toolchain note (read first)

Run everything through mise: `mise exec -- mix test <file>`. If you hit a
`rustler_precompiled` / `validate_quote` crash, the Homebrew Elixir is shadowing
mise's — prepend mise's bin: `PATH="$(mise where elixir)/bin:$PATH" mise exec -- mix test <file>`.
This is a greenfield, unreleased library: do **not** preserve backwards
compatibility or bump cache key versions.

## File Structure

**Create:**
- `lib/image_pipe/response/cors.ex` — neutral CORS helper (before-send registration + OPTIONS responder).
- `test/image_pipe/response/cors_test.exs` — unit test for the helper.

**Modify:**
- `lib/image_pipe/response.ex` — add `CORS` to `Boundary` exports.
- `lib/image_pipe/request/options.ex` — add `:allow_origin` option + validator.
- `lib/image_pipe/plug.ex` — register before-send in `call/2`; add OPTIONS `do_call` clause; `:options` result.
- `test/image_pipe/imgproxy_wire_conformance_test.exs` — add a dialect-neutral CORS `describe` block (reuses the existing imgproxy harness).
- `lib/image_pipe/telemetry/trace/capture.ex` — map `:options` result to span status `:ok`.
- `test/parser/iiif_wire_test.exs` — drop hand-composed CORS; route through `ImagePipe.Plug` with `allow_origin: "*"`; update Contract 8.
- `test/parser/iiif_test.exs` — delete the `ImagePipe.Parser.IIIF.CORSTest` module.
- `test/parser/iiif/openseadragon_sim_test.exs` — drop the CORS wrapper.
- `fiddle/lib/image_pipe_fiddle_web/iiif.ex` — delegate straight to `ImagePipe.Plug`.
- `fiddle/lib/image_pipe_fiddle/application.ex` — add `allow_origin: "*"` to `build_iiif_opts`.
- `docs/iiif_3_support_matrix.md` — update the `cors` row + wire-test note.
- `docs/telemetry.md` — add `:options` to the `[:request]` span result values.

**Delete:**
- `lib/image_pipe/parser/iiif/cors.ex`.

---

## Task 1: `allow_origin` option in `ImagePipe.Request.Options`

**Files:**
- Modify: `lib/image_pipe/request/options.ex`
- Test: `test/image_pipe/request/options_test.exs` (append — this is the `ImagePipe.Request.OptionsTest` file that already covers `allow_debug_headers` with bare `parser:`-only opts, no `sources`)

- [ ] **Step 1: Write the failing test**

Append these three tests inside the existing `ImagePipe.Request.OptionsTest`
module (matching the existing `allow_debug_headers` test style — Imgproxy parser,
no `sources` needed):

```elixir
  test "allow_origin is absent by default (CORS off)" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy)
    refute Keyword.has_key?(opts, :allow_origin)
  end

  test "allow_origin accepts a non-empty string" do
    opts = Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_origin: "*")
    assert Keyword.fetch!(opts, :allow_origin) == "*"
  end

  test "allow_origin rejects an empty string" do
    assert_raise ArgumentError, ~r/allow_origin/, fn ->
      Options.validate!(parser: ImagePipe.Parser.Imgproxy, allow_origin: "")
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/request/options_test.exs`
Expected: FAIL — the empty-string case won't raise (the key passes through
unvalidated), because `:allow_origin` isn't in the schema yet.

- [ ] **Step 3: Add the option to the schema + validator**

In `lib/image_pipe/request/options.ex`:

Add `:allow_origin` to `@validated_option_keys` (after `:allow_debug_headers`):

```elixir
  @validated_option_keys [
    :parser,
    :clock,
    :telemetry_prefix,
    :http_cache,
    :detector,
    :detector_required,
    :max_body_bytes,
    :max_input_pixels,
    :max_result_width,
    :max_result_height,
    :max_result_pixels,
    :auto_avif,
    :auto_webp,
    :auto_jpeg_xl,
    :format_order,
    :allow_debug_headers,
    :allow_origin
  ]
```

Add the schema entry inside `@options_schema` (after the `allow_debug_headers:` entry, before the closing `)`):

```elixir
                    allow_debug_headers: [
                      type: :boolean,
                      default: false
                    ],
                    allow_origin: [
                      type: {:custom, __MODULE__, :validate_allow_origin, []}
                    ]
                  )
```

Add the validator function near `validate_format_order/1`:

```elixir
  @doc false
  def validate_allow_origin(value) when is_binary(value) and value != "",
    do: {:ok, value}

  def validate_allow_origin(""),
    do: {:error, "expected a non-empty string (omit allow_origin to disable CORS)"}

  def validate_allow_origin(_value),
    do: {:error, "expected a string"}
```

No `default:` is set, so an absent `allow_origin` stays absent and downstream `Keyword.get(opts, :allow_origin)` is `nil` (CORS off).

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/request/options_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/request/options.ex test/image_pipe/request/options_test.exs
git commit -m "feat(request): add neutral allow_origin mount option"
```

---

## Task 2: `ImagePipe.Response.CORS` neutral helper

**Files:**
- Create: `lib/image_pipe/response/cors.ex`
- Modify: `lib/image_pipe/response.ex`
- Test: `test/image_pipe/response/cors_test.exs`

- [ ] **Step 1: Write the failing test**

```elixir
# test/image_pipe/response/cors_test.exs
defmodule ImagePipe.Response.CORSTest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn, only: [get_resp_header: 2, send_resp: 3]

  alias ImagePipe.Response.CORS

  describe "maybe_register/2" do
    test "stamps Access-Control-Allow-Origin on send when allow_origin is set" do
      conn =
        conn(:get, "/x")
        |> CORS.maybe_register(allow_origin: "https://example.test")
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == ["https://example.test"]
    end

    test "no-op when allow_origin is absent" do
      conn =
        conn(:get, "/x")
        |> CORS.maybe_register([])
        |> send_resp(200, "ok")

      assert get_resp_header(conn, "access-control-allow-origin") == []
    end
  end

  describe "send_options/2" do
    test "204 + Allow always; Access-Control-Allow-Methods only when CORS on" do
      on = conn(:options, "/x") |> CORS.maybe_register(allow_origin: "*") |> CORS.send_options(allow_origin: "*")
      assert on.status == 204
      assert get_resp_header(on, "allow") == ["GET, HEAD"]
      assert get_resp_header(on, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
      assert get_resp_header(on, "access-control-allow-origin") == ["*"]

      off = conn(:options, "/x") |> CORS.maybe_register([]) |> CORS.send_options([])
      assert off.status == 204
      assert get_resp_header(off, "allow") == ["GET, HEAD"]
      assert get_resp_header(off, "access-control-allow-methods") == []
      assert get_resp_header(off, "access-control-allow-origin") == []
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/response/cors_test.exs`
Expected: FAIL — `ImagePipe.Response.CORS` is undefined.

- [ ] **Step 3: Create the helper module**

```elixir
# lib/image_pipe/response/cors.ex
defmodule ImagePipe.Response.CORS do
  @moduledoc false

  import Plug.Conn, only: [put_resp_header: 3, register_before_send: 2, send_resp: 3]

  @allow "GET, HEAD"
  @allow_methods "GET, HEAD, OPTIONS"

  @doc """
  Register a before-send hook that stamps `Access-Control-Allow-Origin` on every
  response when `allow_origin` is configured, else a no-op. One registration
  covers image, info, redirect, error, 304, OPTIONS, and 405 outcomes.
  """
  @spec maybe_register(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def maybe_register(%Plug.Conn{} = conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil ->
        conn

      origin when is_binary(origin) ->
        register_before_send(conn, fn conn ->
          put_resp_header(conn, "access-control-allow-origin", origin)
        end)
    end
  end

  @doc """
  Answer an `OPTIONS` request: always `204 No Content` + `Allow: GET, HEAD`,
  plus `Access-Control-Allow-Methods` when CORS is configured. The
  `Access-Control-Allow-Origin` header is added by the `maybe_register/2`
  before-send hook, so there is one source for it.
  """
  @spec send_options(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def send_options(%Plug.Conn{} = conn, opts) do
    conn
    |> put_resp_header("allow", @allow)
    |> put_allow_methods(opts)
    |> send_resp(204, "")
  end

  defp put_allow_methods(conn, opts) do
    case Keyword.get(opts, :allow_origin) do
      nil -> conn
      _origin -> put_resp_header(conn, "access-control-allow-methods", @allow_methods)
    end
  end
end
```

- [ ] **Step 4: Export `CORS` from the Response boundary**

In `lib/image_pipe/response.ex`, add `CORS` to the `exports:` list (keep alphabetical):

```elixir
    exports: [
      CacheHeaders,
      CORS,
      Json,
      PreparedStream,
      Sender
    ]
```

- [ ] **Step 5: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/response/cors_test.exs`
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/cors.ex lib/image_pipe/response.ex test/image_pipe/response/cors_test.exs
git commit -m "feat(response): add neutral CORS helper (before-send + OPTIONS)"
```

---

## Task 3: Wire CORS into `ImagePipe.Plug`

**Files:**
- Modify: `lib/image_pipe/plug.ex`
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs` (add a `describe` block)

This wires the helper into the request flow and proves it is dialect-neutral by exercising it through the **imgproxy** parser (no IIIF involved). The test reuses that file's existing harness — `@default_opts` (root `http://origin.test`, `OriginImage` plug), `encoded_source/1`, `call_imgproxy/3`, and `get_resp_header/2` (already imported). For OPTIONS/PUT the parser is never invoked (the core short-circuits before `parse`), so the path string is irrelevant there.

- [ ] **Step 1: Write the failing wire test**

Add this `describe` block to `test/image_pipe/imgproxy_wire_conformance_test.exs` (e.g. just after the existing `test "encoded path source succeeds through a real Plug request"`):

```elixir
  describe "CORS (dialect-neutral, through the imgproxy parser)" do
    test "image response carries Access-Control-Allow-Origin when allow_origin set" do
      encoded = encoded_source("images/beach.jpg")

      conn =
        call_imgproxy(
          "/_/rt:force/w:120/h:90/f:jpeg/#{encoded}",
          [allow_origin: "https://cdn.test"] ++ @default_opts
        )

      assert conn.status == 200
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
    end

    test "OPTIONS → 204 + Allow + CORS headers when allow_origin set" do
      conn =
        conn(:options, "/_/anything")
        |> ImagePipe.Plug.call(ImagePipe.Plug.init([allow_origin: "https://cdn.test"] ++ @default_opts))

      assert conn.status == 204
      assert get_resp_header(conn, "allow") == ["GET, HEAD"]
      assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
    end

    test "OPTIONS → 204 + Allow, no CORS headers when allow_origin unset" do
      conn =
        conn(:options, "/_/anything")
        |> ImagePipe.Plug.call(ImagePipe.Plug.init(@default_opts))

      assert conn.status == 204
      assert get_resp_header(conn, "allow") == ["GET, HEAD"]
      assert get_resp_header(conn, "access-control-allow-methods") == []
      assert get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "PUT → 405 + Allow, and the before-send hook still stamps CORS on a non-2xx outcome" do
      conn =
        conn(:put, "/_/anything")
        |> ImagePipe.Plug.call(ImagePipe.Plug.init([allow_origin: "https://cdn.test"] ++ @default_opts))

      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET, HEAD"]
      # Proves the before-send hook is not 200-only: it fires on the 405 too.
      assert get_resp_header(conn, "access-control-allow-origin") == ["https://cdn.test"]
    end
  end
```

> **Coverage note:** the spec lists `Access-Control-Allow-Origin` on image / info / 303-redirect / **error** / **304**. The before-send hook is registered once in `call/2` and fires for *every* `send_resp`, so all outcomes are covered by the same mechanism. This plan asserts it explicitly on: the 200 image (above), the 405 (above, the non-2xx/error class), the IIIF 303 redirect and IIIF parser-error 4xx (Task 6), and info.json (Task 6). A dedicated 304 assertion is deliberately omitted — it would require standing up conditional-request (`If-None-Match`) infrastructure in the harness for **no additional mechanism coverage** (304 routes through the same `send_resp`/before-send path as the 405, which is asserted).

(If `get_resp_header/2` is not already imported in this file, add `import Plug.Conn, only: [get_resp_header: 2]` near the top — but it is used by the existing `content_type/1` helper, so it should already be available.)

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs --only describe:"CORS (dialect-neutral, through the imgproxy parser)"`
(Or just run the whole file.) Expected: FAIL — `OPTIONS` currently returns `405` (no `204`/`Allow-Methods`), and no `Access-Control-*` headers are stamped.

- [ ] **Step 3: Add the `CORS` alias to `ImagePipe.Plug`**

In `lib/image_pipe/plug.ex`, add to the alias block (after `alias ImagePipe.Plan`):

```elixir
  alias ImagePipe.Response.CORS
```

- [ ] **Step 4: Register the before-send hook in `call/2`**

Modify `call/2` to register the hook before the request span. Change:

```elixir
  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    Telemetry.Trace.maybe_extract_inbound(conn)

    Telemetry.span(telemetry_opts, [:request], request_metadata(conn, opts), fn ->
      {conn, metadata} = do_call(conn, opts)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end
```

to:

```elixir
  @impl Plug
  def call(%Plug.Conn{} = conn, opts) do
    telemetry_opts = Telemetry.telemetry_opts(opts)
    Telemetry.Trace.maybe_extract_inbound(conn)
    conn = CORS.maybe_register(conn, opts)

    Telemetry.span(telemetry_opts, [:request], request_metadata(conn, opts), fn ->
      {conn, metadata} = do_call(conn, opts)
      {conn, Map.put(metadata, :status, conn.status)}
    end)
  end
```

- [ ] **Step 5: Add the OPTIONS `do_call` clause**

Add a new `do_call/2` clause **immediately before** the existing
`when method not in ["GET", "HEAD"]` clause (clause order matters — OPTIONS must
match first):

```elixir
  defp do_call(%Plug.Conn{method: "OPTIONS"} = conn, opts) do
    {conn, _send_metadata} =
      send_response(conn, opts, :options, fn ->
        CORS.send_options(conn, opts)
      end)

    {conn, %{result: :options}}
  end

  defp do_call(%Plug.Conn{method: method} = conn, opts) when method not in ["GET", "HEAD"] do
    {conn, _send_metadata} =
      send_response(conn, opts, :method_not_allowed, fn ->
        Sender.send_method_not_allowed(conn)
      end)

    {conn, %{result: :method_not_allowed}}
  end
```

(The second clause is unchanged — shown for placement.)

- [ ] **Step 6: Run the test (and the whole imgproxy suite) to verify it passes**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS — the 4 new CORS tests pass and there are no regressions (GET/HEAD paths and existing 405 behavior unchanged).

- [ ] **Step 7: Commit**

```bash
git add lib/image_pipe/plug.ex test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "feat(plug): neutral CORS decoration + always-answer OPTIONS"
```

---

## Task 4: OTel span status for the `:options` result

**Files:**
- Modify: `lib/image_pipe/telemetry/trace/capture.ex`
- Test: `test/image_pipe/telemetry/trace/capture_test.exs` (locate the existing capture test; append)

`status_from/1` maps any non-`:ok` result to span status `:error`. A `204`
OPTIONS is a success, so `:options` must map to `:ok`. (Leave `:method_not_allowed`,
`:redirect`, `:not_modified` as-is — out of scope.) Note `status_from/1` is the
**single** result→status mapper and is shared by both the `[:request]` and
`[:send]` spans, which both carry `result: :options` for an OPTIONS request — so
this one edit covers both spans.

- [ ] **Step 1: Write the failing test**

Append a test to `test/image_pipe/telemetry/trace/capture_test.exs` that drives the `[:request]` stop with `result: :options` and asserts the captured span status is `:ok`. Model it on the existing capture tests in that file (reuse their telemetry-emit + capture harness). **Use a unique `telemetry_prefix`** (e.g. `[:"cors_opts_#{System.unique_integer([:positive])}"]`) — `:telemetry` handlers are global and a default-prefix emission from another async test would leak. If the existing tests assert on a `status:` field of a captured span, follow that exact shape. Example shape:

```elixir
  test "request stop with :options result captures span status :ok" do
    # ... attach Capture on a UNIQUE prefix, emit [<prefix>, :request, :stop]
    #     with %{result: :options}, ...
    # assert the captured span's status == :ok (NOT :error)
  end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test <capture_test_path>`
Expected: FAIL — `:options` currently maps to `:error`.

- [ ] **Step 3: Add the `:options` clause to `status_from/1`**

In `lib/image_pipe/telemetry/trace/capture.ex`, change:

```elixir
  defp status_from(meta) do
    case meta[:result] do
      :ok -> :ok
      nil -> :ok
      _other -> :error
    end
  end
```

to:

```elixir
  defp status_from(meta) do
    case meta[:result] do
      :ok -> :ok
      :options -> :ok
      nil -> :ok
      _other -> :error
    end
  end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test <capture_test_path>`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/image_pipe/telemetry/trace/capture.ex test/image_pipe/telemetry/trace/capture_test.exs
git commit -m "feat(telemetry): map :options request result to OTel span status :ok"
```

---

## Task 5: Logger coverage + telemetry docs for `:options`

**Files:**
- Test: `test/image_pipe/telemetry/logger_test.exs` (append)
- Modify: `docs/telemetry.md`

The opt-in Logger renders `[:request]` stops through its generic clause
(`outcome(meta)` → `meta[:result]`), so `:options` needs **no Logger code
change** — only a coverage assertion and a docs line.

- [ ] **Step 1: Write the Logger assertion**

In `test/image_pipe/telemetry/logger_test.exs`, add a test that attaches the Logger, emits a `[:request, :stop]` with `result: :options, status: 204`, and asserts the captured log line surfaces `options`. Use `ExUnit.CaptureLog` and a unique `telemetry_prefix`, matching the existing tests in that file. This is a **coverage-only** assertion (no Logger code changes — the generic `message/3` clause already renders `meta[:result]`), so it is expected to pass on first run rather than fail-first. Example shape:

```elixir
  test "request stop with :options result logs the options outcome" do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        # attach Logger on a unique prefix, emit [<prefix>, :request, :stop]
        # with measurements %{duration: ...} and metadata %{result: :options, status: 204}
      end)

    assert log =~ "request"
    assert log =~ "options"
  end
```

- [ ] **Step 2: Run test to verify it passes (generic clause already handles it)**

Run: `mise exec -- mix test test/image_pipe/telemetry/logger_test.exs`
Expected: PASS — the generic `message/3` clause renders `result: :options`.
(If it FAILS because the assertion text doesn't match the rendered line, adjust the assertion to the actual format, e.g. `"image_pipe request: options"`. Do not change the Logger.)

- [ ] **Step 3: Update `docs/telemetry.md`**

Find the `[:request]` span section (search for the request stop metadata
description) and add `:options` to the enumerated `:result` values, e.g. change
the request-span result note to include: *"… `:options` (an OPTIONS response,
`204`) …"* alongside the existing `:ok` / `:redirect` / `:method_not_allowed` /
error values. Match the surrounding doc style.

- [ ] **Step 4: Commit**

```bash
git add test/image_pipe/telemetry/logger_test.exs docs/telemetry.md
git commit -m "test(telemetry): cover :options result in Logger; document it"
```

---

## Task 6: Delete `ImagePipe.Parser.IIIF.CORS` and migrate its callers

**Files:**
- Delete: `lib/image_pipe/parser/iiif/cors.ex`
- Modify: `test/parser/iiif_test.exs`
- Modify: `test/parser/iiif_wire_test.exs`
- Modify: `test/parser/iiif/openseadragon_sim_test.exs`

- [ ] **Step 1: Delete the unit-test module for the plug**

In `test/parser/iiif_test.exs`, delete the entire second module
`ImagePipe.Parser.IIIF.CORSTest` (from its `defmodule` line through the final
`end` at EOF — currently lines 126–155, including the blank separator line
before it). The neutral behavior is now covered by Tasks 2–3. Leave the first
module (`ImagePipe.Parser.IIIF`'s parser tests) intact.

- [ ] **Step 2: Rework the IIIF wire harness**

In `test/parser/iiif_wire_test.exs`:

Remove the alias line:

```elixir
  alias ImagePipe.Parser.IIIF.CORS
```

Add `allow_origin: "*"` to **every** `iiif_opts*` helper (so the IIIF mount opts
carry CORS). For each helper, add the key at the top level of the keyword list.
Example for `iiif_opts/1`:

```elixir
  defp iiif_opts(origin_plug) do
    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [resolver: static_resolver()],
      allow_origin: "*",
      sources: [
        path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin_plug]}
      ]
    ]
  end
```

Apply the same `allow_origin: "*",` addition to `iiif_opts_tile/2`,
`iiif_opts_bounded/2`, `iiif_opts_with_rgba/0`, and `iiif_opts_quality/2`.

Replace `call_iiif/3` (drop the CORS wrapper):

```elixir
  defp call_iiif(path, opts, req_headers \\ []) do
    initialized = ImagePipe.Plug.init(opts)

    :get
    |> conn(path)
    |> put_script_name(["iiif"])
    |> add_req_headers(req_headers)
    |> ImagePipe.Plug.call(initialized)
  end
```

Replace `call_options/1` to go through `ImagePipe.Plug` (it needs the IIIF opts
now, since CORS lives in the core). Change its signature to accept opts:

```elixir
  defp call_options(path, opts) do
    initialized = ImagePipe.Plug.init(opts)

    :options
    |> conn(path)
    |> put_script_name(["iiif"])
    |> ImagePipe.Plug.call(initialized)
  end
```

- [ ] **Step 3: Update Contract 8 tests**

In `test/parser/iiif_wire_test.exs`, the image/info/redirect CORS assertions
(8a/8b/8c) are unchanged in intent. Replace the OPTIONS test (8d) to use the new
always-answer behavior and pass opts:

```elixir
  test "contract 8d: OPTIONS → 204 with Allow + access-control-allow-methods" do
    conn = call_options("/img/full/max/0/default.jpg", iiif_opts(OriginImage))

    assert conn.status == 204
    assert get_resp_header(conn, "allow") == ["GET, HEAD"]
    assert get_resp_header(conn, "access-control-allow-methods") == ["GET, HEAD, OPTIONS"]
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
```

Also add a new test asserting CORS lands on an **error** response through the
core (the spec lists `error` among the outcomes that must carry the header).
Reuse the existing Contract 9a parser-error path (a 400):

```elixir
  test "contract 8e: error response (400) carries access-control-allow-origin" do
    conn = call_iiif("/img/full/9999,/0/default.jpg", iiif_opts(OriginImage))

    assert conn.status == 400
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
```

- [ ] **Step 4: Drop the CORS wrapper in the OpenSeadragon sim test**

In `test/parser/iiif/openseadragon_sim_test.exs`:

Remove the alias:

```elixir
  alias ImagePipe.Parser.IIIF.CORS
```

Replace `call_iiif/1` (it only issues GETs and does not assert CORS, so just
delegate):

```elixir
  defp call_iiif(path) do
    initialized = ImagePipe.Plug.init(opts())
    conn = :get |> conn(path) |> Map.put(:script_name, ["iiif"])
    ImagePipe.Plug.call(conn, initialized)
  end
```

- [ ] **Step 5: Delete the CORS plug**

```bash
git rm lib/image_pipe/parser/iiif/cors.ex
```

- [ ] **Step 6: Run the affected suites**

Run: `mise exec -- mix test test/parser/iiif_test.exs test/parser/iiif_wire_test.exs test/parser/iiif/openseadragon_sim_test.exs`
Expected: PASS. (If a compile error mentions `ImagePipe.Parser.IIIF.CORS`, a caller was missed — grep `grep -rn "IIIF.CORS" lib test fiddle` and fix.)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor(iiif): delete IIIF.CORS plug; route CORS through core allow_origin"
```

---

## Task 7: Fiddle IIIF mount delegates straight to `ImagePipe.Plug`

**Files:**
- Modify: `fiddle/lib/image_pipe_fiddle_web/iiif.ex`
- Modify: `fiddle/lib/image_pipe_fiddle/application.ex`

- [ ] **Step 1: Add `allow_origin: "*"` to the fiddle IIIF opts**

In `fiddle/lib/image_pipe_fiddle/application.ex`, in `build_iiif_opts/0`, add the
key (top level, before `sources:` or after `allow_debug_headers:` — anywhere at
the top level of the keyword list):

```elixir
  defp build_iiif_opts do
    static_root = Application.app_dir(:image_pipe_fiddle, "priv/static")

    [
      parser: ImagePipe.Parser.IIIF,
      iiif: [
        resolver: {ImagePipe.Parser.IIIF.Resolver.Static, map: iiif_source_map()},
        max_width: 4000,
        max_height: 4000
      ],
      sources: [
        path: {ImagePipe.Source.File, root: static_root, root_id: "static", stable: :trusted}
      ],
      allow_debug_headers: true,
      allow_origin: "*"
    ]
    |> maybe_put_cache(Application.get_env(:image_pipe_fiddle, :cache))
    |> ImagePipe.Plug.init()
  end
```

- [ ] **Step 2: Simplify the mount plug to delegate straight**

Replace `fiddle/lib/image_pipe_fiddle_web/iiif.ex` entirely:

```elixir
defmodule ImagePipeFiddleWeb.IIIF do
  @moduledoc """
  Forwards /iiif-image requests to ImagePipe.Plug with opts built at boot. CORS
  and OPTIONS preflight are handled by ImagePipe.Plug itself via the
  `allow_origin: "*"` mount option.
  """
  @behaviour Plug

  @impl true
  def init(_opts), do: []

  @impl true
  def call(conn, _opts) do
    ImagePipe.Plug.call(
      conn,
      :persistent_term.get({ImagePipeFiddle.Application, :iiif_opts})
    )
  end
end
```

- [ ] **Step 3: Verify the fiddle compiles**

Run: `mise exec -- mix compile --warnings-as-errors` (root) — confirms no lib
references to the deleted plug remain.

- [ ] **Step 4: Commit**

```bash
git add fiddle/lib/image_pipe_fiddle_web/iiif.ex fiddle/lib/image_pipe_fiddle/application.ex
git commit -m "refactor(fiddle): IIIF mount delegates straight to ImagePipe.Plug"
```

---

## Task 8: Update the IIIF conformance doc

**Files:**
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: Rewrite the `cors` row**

Replace the line 108 `cors` row:

```markdown
| `cors` | ✅ | `Access-Control-Allow-Origin: *` on every IIIF response (image, info.json, redirect, errors) + `OPTIONS` preflight → 200, applied by the mount-level `ImagePipe.Parser.IIIF.CORS` plug (the parser's `parse/2` returns a tuple, not a conn, so CORS *must* be mount-level). |
```

with:

```markdown
| `cors` | ✅ | Host sets the neutral `allow_origin` mount option (the canonical IIIF mount uses `allow_origin: "*"`); `ImagePipe.Plug` then stamps `Access-Control-Allow-Origin` on every response (image, info.json, 303 redirect, errors, 304) and answers `OPTIONS` → `204` + `Allow: GET, HEAD` + `Access-Control-Allow-Methods: GET, HEAD, OPTIONS`. CORS is a dialect-neutral core feature, not an IIIF-specific plug. |
```

- [ ] **Step 2: Update the wire-test note (line ~154)**

The wire-test bullet mentions CORS; ensure it still reads accurately (CORS is now
exercised through `ImagePipe.Plug` with `allow_origin: "*"`, not a sibling plug).
Adjust the parenthetical if it names the old plug.

- [ ] **Step 3: Note the static `cors` extraFeature advertisement**

`lib/image_pipe/parser/iiif/info.ex` lists `"cors"` in `@extra_features`
**unconditionally**, so `info.json` advertises the `cors` capability regardless
of whether the host set `allow_origin`. Post-change, that advertisement is
accurate only when CORS is configured — which the canonical IIIF mount does
(`allow_origin: "*"`). Add a one-line note to the `cors` row (or the matrix's
"Diverges / caveats" prose, if present) recording this: *"The `cors`
extraFeature is advertised statically and assumes the host configures
`allow_origin` (the canonical mount does); it is not gated on the option."* Do
**not** make the advertisement conditional — that would couple the IIIF info
renderer to the neutral `allow_origin` mount option for a `SHOULD`-level cosmetic
feature (tracked as possible future work, not part of this change).

- [ ] **Step 4: Commit**

```bash
git add docs/iiif_3_support_matrix.md
git commit -m "docs(iiif): CORS is a neutral allow_origin core feature, not a plug"
```

---

## Task 9: Full verification gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`,
`mix credo --strict`, and `mix test` all PASS.

- [ ] **Step 2: Run the fiddle gate (fiddle was touched)**

Run: `mise run precommit:fiddle`
Expected: PASS. (If it fails on a missing Vite manifest, run
`pnpm -C fiddle/assets run build` first, then retry — see the project notes.)

- [ ] **Step 3: Confirm no lingering references**

Run: `grep -rn "IIIF.CORS\|Parser.IIIF.CORS" lib test fiddle/lib docs/iiif_3_support_matrix.md docs/telemetry.md`
Expected: no matches (historical `docs/superpowers/plans/*` and the design/spec
docs may still mention it — those are historical records, leave them).

- [ ] **Step 4: Final commit (if the gate auto-formatted anything)**

```bash
git add -A
git commit -m "chore: gate fixups for neutral CORS" --allow-empty
```

---

## Self-Review notes (verified against the spec)

- **Spec §1 (option):** Task 1 — `:string`, default `nil`, rejects `""`. ✓
- **Spec §2 (mechanism):** Tasks 2–3 — before-send decoration, always-answer OPTIONS `204` + `Allow`, `Access-Control-Allow-Methods: GET, HEAD, OPTIONS` when CORS on, 405 reserved for other methods. ✓
- **Spec §3 (cache):** before-send applies at send time, after cache read — inherent to `register_before_send`, no cache code touched. ✓ (No dedicated task needed; covered by the wire test asserting the header on a served image.)
- **Spec §4 (telemetry):** Tasks 4–5 — `:options` result tag, OTel status `:ok`, Logger coverage, docs. ✓
- **Spec removals:** Tasks 6–7 — delete `IIIF.CORS`, migrate wire/unit/OSD tests, fiddle delegates straight. ✓
- **Spec docs:** Task 8 — `iiif_3_support_matrix.md` cors row + wire note. ✓
- **Spec tests (neutrality through both parsers):** Task 3 (imgproxy) + Task 6 (IIIF). ✓
- **Boundary:** core (`ImagePipe.Plug`) names no dialect — it calls only `ImagePipe.Response.CORS` and reads the neutral `allow_origin`. Existing `architecture_boundary_test.exs` continues to pass unchanged; no new architecture assertion needed (CORS never named a dialect post-change). ✓
