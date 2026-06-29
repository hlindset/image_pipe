# Error → HTTP-status mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Sender`'s flat error→status mapping with one classifier (`Response.ErrorStatus`) that routes every internal failure reason to a `{status, message}` — unifying #267 (transform) and #160 (source), including imgproxy-shaped source codes with upstream-4xx passthrough.

**Architecture:** A new `ImagePipe.Response.ErrorStatus` owns `classify/1` (reason → closed class vocabulary, class-leading-first), `default_status_code/1` (class → HTTP status, with a `{:passthrough, code}` clamp), `message_for/1` (reason → distinct copy), and `resolve_status/2` combining them. `Sender` collapses its per-tag clauses into one generic clause that calls `resolve_status`, threading `opts` so the deferred host override is local later; the `{:render, inner}` unwrap arms, the encode/cache/config, and the render-exception paths stay special. Source errors route through the same table at both render sites (streaming via the generic clause; resolve-time via `send_source_error`).

**Tech Stack:** Elixir, Plug, ExUnit, `Boundary`. Run everything via `mise exec -- ...`.

**Spec:** `docs/superpowers/specs/2026-06-29-error-status-mapping-design.md`

**Scope note — IIIF out-of-bounds-region 400 is DEFERRED.** It would land in the shared `Transform.Operation.Crop` op, an unverified behavior change for TwicPics (which may clamp a past-edge region). It is tracked as a separate IIIF-gated follow-up; this change only **corrects the IIIF matrix** to state the truthful current behavior. The class vocabulary is already exercised by the real `Resize` upscale `:bad_request` producer.

**Conventions:**
- Run a single test file: `mise exec -- mix test test/path_test.exs`
- Final gate (Task 5): `mise run precommit`
- Commit after every green step. Do not push until the end.

---

## File structure

- **Create** `lib/image_pipe/response/error_status.ex` — classifier + tables (`ImagePipe.Response.ErrorStatus`, internal to the `Response` boundary, **not** exported).
- **Create** `test/image_pipe/response/error_status_test.exs` — classifier contract test.
- **Modify** `lib/image_pipe/response/sender.ex` — collapse the pure status clauses into one generic clause via `resolve_status`; thread `opts`; rewrite `send_source_error`; **keep** the `{:render, inner}` unwrap arms (made arity 4), the generic `{:render, reason}`→500, and the encode/cache/config/exception paths.
- **Modify** `lib/image_pipe/plug.ex:123` — pass `opts` into `Sender.send_source_error/3`.
- **Modify** `test/image_pipe/imgproxy_wire_conformance_test.exs` — source-status wire tests.
- **Modify** `docs/imgproxy_support_matrix.md`, `docs/iiif_3_support_matrix.md` — behavioral status updates / matrix correction.

No `ReqStream`/`Source`/`crop.ex` change: source reasons are already distinct; the OOB producer is deferred.

---

## Task 1: `Response.ErrorStatus` module

**Files:**
- Create: `lib/image_pipe/response/error_status.ex`
- Test: `test/image_pipe/response/error_status_test.exs`

- [ ] **Step 1: Write the failing test**

Create `test/image_pipe/response/error_status_test.exs`:

```elixir
defmodule ImagePipe.Response.ErrorStatusTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Response.ErrorStatus

  describe "resolve_status/1 — status axis" do
    test "transform bad_request details all map to 400 (open detail)" do
      assert {400, _} = ErrorStatus.resolve_status({:transform_error, {:bad_request, :upscale_required}})
      assert {400, _} = ErrorStatus.resolve_status({:transform_error, {:bad_request, :some_future_detail}})
    end

    test "generic transform / plan-validation / empty pipeline stay 422" do
      assert {422, _} = ErrorStatus.resolve_status({:transform_error, {SomeMod, :boom}})
      assert {422, _} = ErrorStatus.resolve_status({:invalid_pipeline_operation, :x})
      assert {422, _} = ErrorStatus.resolve_status(:empty_pipeline_plan)
    end

    test "source transport reasons map imgproxy-shaped" do
      assert {404, _} = ErrorStatus.resolve_status({:source, :connect_error})
      assert {404, _} = ErrorStatus.resolve_status({:source, :too_many_redirects})
      assert {502, _} = ErrorStatus.resolve_status({:source, {:bad_status, 503}})
      assert {451, _} = ErrorStatus.resolve_status({:source, {:bad_status, 451}})
      assert {404, _} = ErrorStatus.resolve_status({:source, {:bad_status, 199}})
      assert {504, _} = ErrorStatus.resolve_status({:source, :receive_timeout})
      assert {422, _} = ErrorStatus.resolve_status({:source, :body_too_large})
      assert {422, _} = ErrorStatus.resolve_status({:source, :invalid_body})
      assert {500, _} = ErrorStatus.resolve_status({:source, :invalid_adapter_config})
    end

    test "unrecognized source reason falls back to 422; unknown top-level to 500" do
      assert {422, _} = ErrorStatus.resolve_status({:source, :some_host_adapter_reason})
      assert {500, _} = ErrorStatus.resolve_status(:totally_unknown)
    end

    test "decode/input-limit/unsupported-output unchanged" do
      assert {415, _} = ErrorStatus.resolve_status({:decode, :x})
      assert {415, _} = ErrorStatus.resolve_status(:source_format_required)
      assert {413, _} = ErrorStatus.resolve_status({:input_limit, :x})
      assert {501, _} = ErrorStatus.resolve_status({:unsupported_output_format, :jp2})
    end

    test "class-leading custom reason routes by class from any producer" do
      assert {404, _} = ErrorStatus.resolve_status({:source, {:not_found, :my_detail}})
      assert {504, _} = ErrorStatus.resolve_status({:render, {:source, :receive_timeout}})
    end

    test "passthrough echoes the code, clamping an out-of-range value to 502" do
      assert {451, _} = ErrorStatus.resolve_status({:source, {:passthrough, 451}})
      assert {502, _} = ErrorStatus.resolve_status({:source, {:passthrough, 999}})
    end
  end

  describe "resolve_status/1 — message axis" do
    test "messages are distinct across reasons and never embed a URL" do
      reasons = [
        {:transform_error, {:bad_request, :upscale_required}},
        {:transform_error, {SomeMod, :boom}},
        {:source, :connect_error},
        {:source, :too_many_redirects},
        {:source, {:bad_status, 503}},
        {:source, :receive_timeout},
        {:source, :body_too_large},
        {:source, :invalid_body},
        {:decode, :x},
        {:input_limit, :x},
        {:unsupported_output_format, :jp2}
      ]

      messages = Enum.map(reasons, fn r -> elem(ErrorStatus.resolve_status(r), 1) end)

      assert length(Enum.uniq(messages)) == length(messages), "messages must be distinct"
      assert Enum.all?(messages, &(not String.contains?(&1, ["http://", "https://"])))
    end

    test "bad_status message interpolates the upstream code" do
      assert {_, "upstream responded 503"} = ErrorStatus.resolve_status({:source, {:bad_status, 503}})
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `mise exec -- mix test test/image_pipe/response/error_status_test.exs`
Expected: FAIL — `ImagePipe.Response.ErrorStatus` is undefined.

- [ ] **Step 3: Write the module**

Create `lib/image_pipe/response/error_status.ex`:

```elixir
defmodule ImagePipe.Response.ErrorStatus do
  @moduledoc false
  # Maps an internal processing failure reason to a client-facing
  # {http_status, message}. Status is keyed on a small closed class vocabulary
  # (the host-override seam); message is keyed on the full reason. classify/1
  # resolves a class-leading reason first ({<known_class>, _detail}), then the
  # core domain table, then a total fallback. See
  # docs/superpowers/specs/2026-06-29-error-status-mapping-design.md.

  @type class ::
          :bad_request
          | :unprocessable
          | :not_found
          | :bad_gateway
          | :gateway_timeout
          | :payload_too_large
          | :unsupported_media
          | :unsupported_output
          | :server_error
          | {:passthrough, integer()}

  # Classes a producer may assert as the lead atom of a reason. Deliberately
  # distinct from the core domain reason tags (:bad_status, :connect_error,
  # :decode, :input_limit, :unsupported_output_format, …) so a domain reason can
  # never be mistaken for a class lead.
  @leading_classes [
    :bad_request,
    :not_found,
    :bad_gateway,
    :gateway_timeout,
    :payload_too_large,
    :unsupported_media,
    :unsupported_output,
    :server_error
  ]

  @plan_validation_error_tags [
    :unsupported_source,
    :invalid_output_plan,
    :invalid_expires,
    :invalid_cachebuster,
    :invalid_response_plan,
    :invalid_pipeline_plan,
    :invalid_pipeline_operation,
    :unprojectable_operation_for_cache_adapter,
    :detector_unavailable
  ]

  @spec resolve_status(term(), keyword()) :: {100..599, String.t()}
  def resolve_status(reason, _opts \\ []) do
    # _opts is the Option-A seam: a future host policy is consulted here before
    # the default table. Threaded now so adding it touches only this function.
    {default_status_code(classify(reason)), message_for(reason)}
  end

  # --- classification -------------------------------------------------------

  @spec classify(term()) :: class()
  def classify({:transform_error, inner}), do: class_lead(inner) || :unprocessable
  def classify({:render, inner}), do: classify(inner)
  def classify({:source, inner}), do: class_lead(inner) || source_domain_class(inner)
  def classify({:decode, _}), do: :unsupported_media
  def classify({:unsupported_source_format, _}), do: :unsupported_media
  def classify(:source_format_required), do: :unsupported_media
  def classify({:input_limit, _}), do: :payload_too_large
  def classify({:unsupported_output_format, _}), do: :unsupported_output
  def classify({:encode, _}), do: :server_error
  def classify({:encode, _, _}), do: :server_error
  def classify({:cache_write, _}), do: :server_error
  def classify({:config, _}), do: :server_error
  def classify(:empty_pipeline_plan), do: :unprocessable
  def classify({tag, _}) when tag in @plan_validation_error_tags, do: :unprocessable
  def classify(_other), do: :server_error

  # Step 1: a reason that leads with a known class atom routes by that class.
  # Passthrough accepts any integer; the status table clamps to a valid range.
  defp class_lead({:passthrough, code}) when is_integer(code), do: {:passthrough, code}
  defp class_lead({class, _detail}) when class in @leading_classes, do: class
  defp class_lead(_), do: nil

  # Step 2: core source domain reasons. Step 3 (fallback) is the last clause.
  defp source_domain_class(:connect_error), do: :not_found
  defp source_domain_class(:too_many_redirects), do: :not_found
  defp source_domain_class(:redirect_not_followed), do: :not_found
  defp source_domain_class(:invalid_redirect), do: :not_found
  defp source_domain_class(:receive_timeout), do: :gateway_timeout
  defp source_domain_class(:body_too_large), do: :unprocessable
  defp source_domain_class(:invalid_body), do: :unprocessable
  defp source_domain_class(:invalid_stream_chunk), do: :unprocessable
  defp source_domain_class(:stream_exception), do: :unprocessable
  defp source_domain_class(:invalid_adapter_result), do: :server_error
  defp source_domain_class(:invalid_adapter_config), do: :server_error
  defp source_domain_class(:missing_adapter), do: :server_error
  defp source_domain_class({:bad_status, code}) when code in 400..499, do: {:passthrough, code}
  defp source_domain_class({:bad_status, code}) when code in 500..599, do: :bad_gateway
  defp source_domain_class({:bad_status, _code}), do: :not_found
  defp source_domain_class(_other), do: :unprocessable

  # --- status table ---------------------------------------------------------

  @spec default_status_code(class()) :: 100..599
  defp default_status_code(:bad_request), do: 400
  defp default_status_code(:unprocessable), do: 422
  defp default_status_code(:not_found), do: 404
  defp default_status_code(:bad_gateway), do: 502
  defp default_status_code(:gateway_timeout), do: 504
  defp default_status_code(:payload_too_large), do: 413
  defp default_status_code(:unsupported_media), do: 415
  defp default_status_code(:unsupported_output), do: 501
  defp default_status_code(:server_error), do: 500
  defp default_status_code({:passthrough, code}) when is_integer(code) and code in 100..599, do: code
  defp default_status_code({:passthrough, _code}), do: 502

  # --- message table (reason-keyed; specific, never embeds a URL) ------------

  @spec message_for(term()) :: String.t()
  def message_for({:transform_error, {:bad_request, :upscale_required}}),
    do: "upscaling requires the ^ prefix"

  def message_for({:transform_error, {:bad_request, _}}), do: "bad request"
  def message_for({:transform_error, _}), do: "invalid image transform"
  def message_for({:render, inner}), do: message_for(inner)
  def message_for({:source, {:bad_status, code}}), do: "upstream responded #{code}"
  def message_for({:source, :connect_error}), do: "source unreachable"
  def message_for({:source, :too_many_redirects}), do: "too many redirects"
  def message_for({:source, :redirect_not_followed}), do: "redirect not followed"
  def message_for({:source, :invalid_redirect}), do: "invalid redirect"
  def message_for({:source, :receive_timeout}), do: "source timeout"
  def message_for({:source, :body_too_large}), do: "source response exceeds the size limit"

  def message_for({:source, reason})
      when reason in [:invalid_body, :invalid_stream_chunk, :stream_exception],
      do: "incomplete source response"

  def message_for({:source, reason})
      when reason in [:invalid_adapter_result, :invalid_adapter_config, :missing_adapter],
      do: "configuration error"

  def message_for({:decode, _}), do: "source response is not a supported image"
  def message_for({:unsupported_source_format, _}), do: "source response is not a supported image"
  def message_for(:source_format_required), do: "source response is not a supported image"
  def message_for({:input_limit, _}), do: "source image is too large"

  def message_for({:unsupported_output_format, _}),
    do: "requested output format is not supported by this server"

  def message_for({:cache_write, _}), do: "cache error"
  def message_for({:config, _}), do: "configuration error"
  def message_for({:encode, _}), do: "error encoding image"
  def message_for({:encode, _, _}), do: "error encoding image"
  def message_for(reason), do: class_default_message(classify(reason))

  defp class_default_message(:bad_request), do: "bad request"
  defp class_default_message(:unprocessable), do: "unprocessable image request"
  defp class_default_message(:not_found), do: "source not found"
  defp class_default_message(:bad_gateway), do: "bad gateway"
  defp class_default_message(:gateway_timeout), do: "source timeout"
  defp class_default_message(:payload_too_large), do: "source image is too large"
  defp class_default_message(:unsupported_media), do: "source response is not a supported image"

  defp class_default_message(:unsupported_output),
    do: "requested output format is not supported by this server"

  defp class_default_message(:server_error), do: "internal server error"
  defp class_default_message({:passthrough, _}), do: "upstream error"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `mise exec -- mix test test/image_pipe/response/error_status_test.exs`
Expected: PASS (all assertions).

- [ ] **Step 5: Compile clean (Boundary + warnings)**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: compiles; no Boundary violation (ErrorStatus is within the `Response` boundary and unexported; Boundary does not check `test/` — precedent: `test/image_pipe/output/encode_search_test.exs` calls the unexported `Output.EncodeSearch`).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/error_status.ex test/image_pipe/response/error_status_test.exs
git commit -m "Add Response.ErrorStatus classifier (reason -> {status, message})"
```

---

## Task 2: Route the transform/plan/decode side through `ErrorStatus` in `Sender`

Collapse the pure status clauses into one generic clause; thread `opts`. **Keep** the `{:render, inner}` unwrap arms (as thin re-dispatchers, now arity 4), the generic `{:render, reason}`→500, and the encode/cache/config/exception paths (they log + 500).

**Files:**
- Modify: `lib/image_pipe/response/sender.ex`

- [ ] **Step 1: Thread `opts` into the error dispatch**

In `send_result/3`, change the error clause to pass `opts` through.

Find (`sender.ex:90-96`):

```elixir
  def send_result(
        conn,
        {:error, {:processing, reason, response_headers}},
        _opts
      ) do
    handle_processing_error(conn, reason, response_headers)
  end
```

Replace with:

```elixir
  def send_result(
        conn,
        {:error, {:processing, reason, response_headers}},
        opts
      ) do
    handle_processing_error(conn, reason, response_headers, opts)
  end
```

- [ ] **Step 2: Add the alias**

In the `alias` block near the top of `sender.ex`, add:

```elixir
  alias ImagePipe.Response.ErrorStatus
```

- [ ] **Step 3: Delete the subsumed pure clauses and unused senders**

DELETE these `handle_processing_error/3` clauses (subsumed by the generic clause + `ErrorStatus.classify`):
- `{:transform_error, {:bad_request, _}}` (`sender.ex:135-142`)
- `{:transform_error, reason}` (`:144-151`)
- `{:source, error}` (`:153-154`) — source now flows through the generic clause (streaming) and `send_source_error` (resolve-time, Task 3)
- `{:decode, error}` (`:156-157`), `{:unsupported_source_format, _}` (`:159-160`), `:source_format_required` (`:162-163`), `{:input_limit, error}` (`:165-166`)
- `{:unsupported_output_format, _}` (`:185-192`)
- the `@plan_validation_error_tags` guarded clause (`:226-229`) and `send_plan_validation_error/3` (`:231-234`)
- `:empty_pipeline_plan` (`:182-183`) — **this one is easy to miss**; it calls `send_plan_validation_error/3` which is deleted, so leaving it causes a compile error. `classify(:empty_pipeline_plan)` → 422 via the generic clause.
- the now-unused private senders: `send_transform_error/2`, `send_bad_request_error/2`, `send_unsupported_output_format_error/2`, `send_decode_error/3`, `send_input_limit_error/3`
- the `@plan_validation_error_tags` **module attribute** (`:39-49`) — remove it cleanly (no stray comment in its place); it lives in `ErrorStatus` now.

**KEEP** (do not delete): the `{:render, {:decode,_}}`, `{:render, {:source,_}}`, `{:render, {:unsupported_source_format,_}}`, `{:render, :source_format_required}`, `{:render, {:input_limit,_}}` unwrap arms (`:194-215`); the generic `{:render, reason}`→500 (`:217-224`); the `{:encode, exception, stacktrace}`, `{:encode, :empty_stream}`, `{:cache_write,_}`, `{:config,_}` clauses + `send_encode_error`/`send_cache_error`/`send_config_error`/`handle_encode_exception`.

- [ ] **Step 4: Give every kept `handle_processing_error` clause arity 4, and add the generic clause LAST**

All `handle_processing_error` clauses must be the same arity (4) and **contiguous**, specific-before-generic. Update the kept clauses' heads to add `, opts` (or `, _opts` where unused). The `{:render, inner}` unwrap arms must re-dispatch **with** `opts`:

```elixir
  defp handle_processing_error(conn, {:encode, exception, stacktrace}, response_headers, _opts),
    do: handle_encode_exception(exception, stacktrace, conn, response_headers)

  defp handle_processing_error(conn, {:encode, :empty_stream}, response_headers, _opts) do
    Logger.error("encode_error: empty_stream")
    send_encode_error(conn, response_headers)
  end

  defp handle_processing_error(conn, {:cache_write, error}, response_headers, _opts),
    do: send_cache_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:config, error}, response_headers, _opts),
    do: send_config_error(conn, error, response_headers)

  defp handle_processing_error(conn, {:render, {:decode, _} = inner}, response_headers, opts),
    do: handle_processing_error(conn, inner, response_headers, opts)

  defp handle_processing_error(conn, {:render, {:source, _} = inner}, response_headers, opts),
    do: handle_processing_error(conn, inner, response_headers, opts)

  defp handle_processing_error(
         conn,
         {:render, {:unsupported_source_format, _} = inner},
         response_headers,
         opts
       ),
       do: handle_processing_error(conn, inner, response_headers, opts)

  defp handle_processing_error(conn, {:render, :source_format_required = inner}, response_headers, opts),
    do: handle_processing_error(conn, inner, response_headers, opts)

  defp handle_processing_error(conn, {:render, {:input_limit, _} = inner}, response_headers, opts),
    do: handle_processing_error(conn, inner, response_headers, opts)

  defp handle_processing_error(conn, {:render, reason}, response_headers, _opts) do
    Logger.error("render_error: #{inspect(reason)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error rendering response")
  end

  # Generic catch-all — MUST be the last handle_processing_error clause.
  defp handle_processing_error(conn, reason, response_headers, opts) do
    {status, message} = ErrorStatus.resolve_status(reason, opts)
    Logger.info("processing_error: #{status} #{inspect(reason)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end
```

> `opts` is the request-options keyword `send_result/3` already receives; `ErrorStatus.resolve_status/2` ignores it today (Option A deferred). Pass it verbatim — do not add a `host_policy/1` (that's the future change).

- [ ] **Step 5: Run the existing wire suite as regression**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. Transform 422s, decode 415s, input-limit 413s, unsupported-output 501s, and the existing upscale 400 resolve identically. `{:render, {:source,_}}`-wrapped errors still route to the inner reason.

- [ ] **Step 6: Compile + format, then commit**

```bash
mise exec -- mix compile --warnings-as-errors && mise exec -- mix format
git add lib/image_pipe/response/sender.ex
git commit -m "Route transform/plan/decode errors through ErrorStatus; thread opts"
```

---

## Task 3: Route source errors through `ErrorStatus` (both render sites) — #160

**Files:**
- Modify: `lib/image_pipe/response/sender.ex` (rewrite `send_source_error`)
- Modify: `lib/image_pipe/plug.ex:123` (pass `opts`)
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Write the failing wire tests**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, add fixed-status origin plugs near the other origin modules (do **not** use a query param — the `?status=` query never reaches the origin; the fetch URL is built from source segments only):

```elixir
  defmodule Origin503 do
    @moduledoc false
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 503, "origin 503")
  end

  defmodule Origin451 do
    @moduledoc false
    def call(conn, _opts), do: Plug.Conn.send_resp(conn, 451, "origin 451")
  end

  # Minimal Source adapter whose resolve/3 fails BEFORE any fetch — exercises the
  # resolve-time send_source_error path (plug.ex), distinct from the streaming path.
  defmodule ResolveDeniedSource do
    @moduledoc false
    @behaviour ImagePipe.Source
    @impl true
    def validate_options(opts), do: {:ok, opts}
    @impl true
    def resolve(_source, _opts, _runtime_opts), do: {:error, {:source, :connect_error}}
    @impl true
    def fetch(_resolved, _opts, _runtime_opts), do: {:error, {:source, :connect_error}}
  end
```

Add the tests (the `@default_opts`, `call_imgproxy/2`, `RootHTTPAdapter`, `CacheProbe` helpers already exist in this file):

```elixir
  describe "source-fetch failures map to imgproxy-shaped statuses (#160)" do
    defp origin_opts(origin) do
      Keyword.merge(@default_opts,
        sources: [path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: origin]}]
      )
    end

    test "upstream 5xx -> 502 bad gateway, and does NOT cache the failure" do
      opts = Keyword.merge(origin_opts(Origin503), cache: {CacheProbe, []})
      conn = call_imgproxy("/_/rs:fit:50:50/plain/images/x.jpg", opts)

      assert conn.status == 502
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body == "upstream responded 503"
      refute_received {:cache_put, _key, _entry}
    end

    test "upstream 4xx passes through (arbitrary code)" do
      conn = call_imgproxy("/_/rs:fit:50:50/plain/images/x.jpg", origin_opts(Origin451))
      assert conn.status == 451
      assert conn.resp_body == "upstream responded 451"
    end

    test "resolve-time source error renders via send_source_error (connect_error -> 404)" do
      opts = Keyword.merge(@default_opts, sources: [path: {ResolveDeniedSource, []}])
      conn = call_imgproxy("/_/rs:fit:50:50/plain/images/x.jpg", opts)

      assert conn.status == 404
      assert conn.resp_body == "source unreachable"
    end
  end
```

> If `cache: {CacheProbe, []}` + `refute_received {:cache_put, …}` does not match this file's exact CacheProbe message shape, mirror an existing `refute_received` cache assertion already in the file (search for `:cache_put`/`CacheProbe`) and copy its message pattern. The intent: a source failure must not write a cache entry.

- [ ] **Step 2: Run to verify they fail**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: the 3 new tests FAIL — current code returns 422 "invalid image source" for all.

- [ ] **Step 3: Rewrite `send_source_error` to use `ErrorStatus`**

In `sender.ex`, replace the two `send_source_error` heads (`:98-108`) with an `opts`-aware version. (The streaming source path now flows through the generic `handle_processing_error/4` clause; the only remaining caller of `send_source_error` is the resolve-time `plug.ex` path, which passes no `response_headers`.)

```elixir
  @spec send_source_error(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def send_source_error(%Plug.Conn{} = conn, error), do: send_source_error(conn, error, [])

  @spec send_source_error(Plug.Conn.t(), term(), keyword()) :: Plug.Conn.t()
  def send_source_error(%Plug.Conn{} = conn, error, opts) do
    {status, message} = ErrorStatus.resolve_status({:source, error}, opts)
    Logger.info("source_error: #{status} #{inspect(error)}")

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end
```

- [ ] **Step 4: Pass `opts` from `plug.ex`**

In `lib/image_pipe/plug.ex`, the source-error branch (around `:121-125`) calls `Sender.send_source_error(conn, error)` inside a `send_response(...)` wrapper. Change **only the inner call** to thread `opts` (which is already in scope in that clause):

Find:

```elixir
          send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error) end)
```

Replace:

```elixir
          send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error, opts) end)
```

- [ ] **Step 5: Run the new tests + the full wire file**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS (502 / 451 / 404 green; existing tests unaffected).

- [ ] **Step 6: Compile + format, then commit**

```bash
mise exec -- mix compile --warnings-as-errors && mise exec -- mix format
git add lib/image_pipe/response/sender.ex lib/image_pipe/plug.ex test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "Map source-fetch failures to imgproxy-shaped statuses via ErrorStatus (#160)"
```

---

## Task 4: Conformance-matrix updates

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: imgproxy matrix — source-fetch-failure status rows (behavioral)**

In `docs/imgproxy_support_matrix.md`, add the source-fetch-failure status mapping, parity-confirmed against `/Users/hlindset/src/imgproxy`:

```markdown
### Source-fetch failure → HTTP status (behavioral, [#160](https://github.com/hlindset/image_pipe/issues/160))

| Fetch failure | ImagePipe | imgproxy | Parity |
| --- | --- | --- | --- |
| Unreachable / connect error | 404 | 404 (`fetcher/errors.go:37`) | ✅ |
| Too many redirects | 404 | 404 (`:109`) | ✅ |
| Upstream 4xx | passthrough that 4xx | passthrough (`:89-91`) | ✅ |
| Upstream 5xx | 502 | 502 (`:93`) | ✅ |
| Request timeout (per-message read) | 504 | 504 (`:131`) | ✅ |
| Oversized / incomplete body | 422 | 422 (`imagedata/errors.go:17`, `fetcher/errors.go:171`) | ✅ |

**Diverges (non-status):** error *body* copy is distinct per reason
(`upstream responded 503`, `source timeout`, …); imgproxy returns a single
uniform "Source is unreachable" string. Status (the wire-observable axis)
matches; body copy is a deliberate, product-neutral divergence. The 60s
wedged-session backstop stays 500 (internal stall, not source liveness;
imgproxy's *whole-request* timeout is 503, a separate concern). imgproxy's 499
request-canceled has no analogue (ImagePipe handles disconnect via prompt
encode-kill). The pre-existing unsupported-output → 501 and
unsupported-source-format → 415 rows are unchanged ImagePipe divergences from
imgproxy's 422 and are **not** claimed as parity here.
```

- [ ] **Step 2: iiif matrix — correct the OOB-region row to truthful current behavior**

In `docs/iiif_3_support_matrix.md`, the region row (`:29`) and runtime-error row (`:120-122`) currently claim a wholly-out-of-bounds region → **400**, which is **not implemented** (the shared `Crop` op clamps to an edge strip). Correct them to the truthful current behavior and mark the 400 as deferred. Replace the "400 / wholly out of bounds" assertions with:

```markdown
> **Out-of-bounds region (deferred — [#427](https://github.com/hlindset/image_pipe/issues/427)):**
> a region wholly outside the image *should* be 400 per IIIF (spec §41 /
> spec.md:192), but is **not yet implemented** — the shared
> `Transform.Operation.Crop` op currently clamps to the nearest in-bounds strip
> (200). Wiring the 400 must be IIIF-gated (the op is shared with TwicPics, whose
> region-OOB behavior is undocumented), tracked in
> [#427](https://github.com/hlindset/image_pipe/issues/427) rather than made an
> unconditional change here. The runtime 400 for no-`^` upscale *is* implemented
> (via `{:transform_error, {:bad_request, _}}` routed by
> `ImagePipe.Response.ErrorStatus`). If a future deployment disables `^`
> upscaling, the correct status is **501** (`:unsupported_output`), not 400.
```

Update the region table rows (`:29`, `:120-122`) so they no longer assert an implemented 400 for the wholly-outside case — say "clamps to edge (200); spec-400 deferred" instead.

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/iiif_3_support_matrix.md
git commit -m "Docs: source-status parity table (#160); correct IIIF OOB-region row (400 deferred)"
```

---

## Task 5: Final gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix test` all green.

- [ ] **Step 2: Fix anything the gate surfaces, re-run, commit fixes**

If credo flags the new module (flat pattern-match dispatch is usually accepted; if a `classify`/`message_for` complexity check trips, satisfy it without logic change), fix and re-run `mise run precommit`.

```bash
git add -A
git commit -m "Satisfy precommit gate for error-status mapping"
```

- [ ] **Step 3: Final review handoff**

Request one final parallel review of the complete diff with a **compatibility (imgproxy) lens** (confirm the source-status table against `fetcher/errors.go`). The shared-`Crop` OOB change is deferred, so TwicPics is not touched by this change — note that for the reviewer. Use `superpowers:requesting-code-review`.

- [ ] **Step 4: (follow-up) IIIF OOB-400 tracking issue**

Filed as [#427](https://github.com/hlindset/image_pipe/issues/427) (IIIF-gated
`reject_out_of_bounds` policy). The corrected matrix (Task 4 Step 2) links it. No
action needed in this change.

---

## Self-review notes (coverage map)

- **Class vocabulary + status table + passthrough clamp** → Task 1.
- **Reason-keyed messages + distinctness/no-URL** → Task 1.
- **Custom reason atoms / class-leading routing** → Task 1.
- **Total classification / unrecognized fallback** → Task 1.
- **#267 transform unification + opts seam + kept render-unwrap arms** → Task 2.
- **#160 source unification, both render sites (streaming via generic clause; resolve-time via send_source_error)** → Tasks 2 + 3.
- **`{:passthrough, code}` guard** → Task 1 + Task 3 (451 passthrough wire test).
- **Returns-before-cache-write** → Task 3 (503 test `refute_received`).
- **Session backstop stays 500** → no code change (intentionally untouched).
- **IIIF OOB-region 400** → DEFERRED; matrix corrected (Task 4 Step 2); tracked follow-up (Task 5 Step 4).
- **Matrices (behavioral axis)** → Task 4.
- **Final compat review** → Task 5 Step 3.

**Known unit-only coverage (justified):** `receive_timeout → 504` and `{:render, {:source, _}} → 504` are covered at the classifier (Task 1), not the wire — both need a trickling-origin / render-phase source failure that is not deterministically simulable in a fast wire test. `body_too_large → 422` (byte limit) is covered at the unit level; the resolve-time `connect_error → 404` wire test exercises the source render path that matters for the Task 3 rewrite.
