# Error → HTTP-status mapping Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `Sender`'s flat error→status mapping with one classifier (`Response.ErrorStatus`) that routes every internal failure reason to a `{status, message}` — unifying #267 (transform) and #160 (source), incl. imgproxy-shaped source codes and a new IIIF out-of-bounds-region 400.

**Architecture:** A new `ImagePipe.Response.ErrorStatus` owns `classify/1` (reason → closed class vocabulary, class-leading-first), `default_status_code/1` (class → HTTP status, with a `{:passthrough, code}` clamp), `message_for/1` (reason → distinct copy), and `resolve_status/2` combining them. `Sender` collapses its per-tag clauses into one generic clause that calls `resolve_status`, threading `opts` so the deferred host override is local later; the encode/cache/config/render-exception paths stay special (they log + 500). Source errors route through the same table at both render sites. A new `:bad_request` producer (the shared `Crop` op) emits `{:bad_request, :region_out_of_bounds}` for a wholly-outside region.

**Tech Stack:** Elixir, Plug, ExUnit, `Boundary`. Run everything via `mise exec -- ...`.

**Spec:** `docs/superpowers/specs/2026-06-29-error-status-mapping-design.md`

**Conventions:**
- Run a single test file: `mise exec -- mix test test/path_test.exs`
- Run one test: `mise exec -- mix test test/path_test.exs:LINE`
- Final gate (Task 6): `mise run precommit`
- Commit after every green step. Branch is already a worktree branch; do not push until the end.

---

## File structure

- **Create** `lib/image_pipe/response/error_status.ex` — the classifier + tables (`ImagePipe.Response.ErrorStatus`, internal to the `Response` boundary, **not** exported).
- **Create** `test/image_pipe/response/error_status_test.exs` — classifier contract test.
- **Modify** `lib/image_pipe/response/sender.ex` — collapse pure status clauses into one generic clause via `resolve_status`; thread `opts`; rewrite `send_source_error`; delete the `{:bad_request,_}` one-off, the `@plan_validation_error_tags` send, the per-tag source/decode/input-limit/unsupported-output clauses, and the subsumed `{:render, inner}` unwrap arms. Keep encode/cache/config/render-generic/exception paths.
- **Modify** `lib/image_pipe/plug.ex:121-125` — pass `opts` into `Sender.send_source_error/3`.
- **Modify** `lib/image_pipe/transform/operation/crop.ex` — `execute/2` passes `{:bad_request, _}` through unwrapped; the region (`crop_from` map) branch of `crop_coordinates/4` detects a wholly-outside region.
- **Modify** `test/image_pipe/imgproxy_wire_conformance_test.exs` — add source-status wire tests (a failing-origin plug + assertions).
- **Modify** `test/parser/iiif_wire_test.exs` — add the OOB-region → 400 wire test.
- **Modify** `docs/imgproxy_support_matrix.md`, `docs/iiif_3_support_matrix.md` — behavioral status-row updates.

No `ReqStream`/`Source` change: the source reasons (`:connect_error`, `:receive_timeout`, `{:bad_status, code}` with the code, redirect/body variants) are **already distinct**; the source side is purely classifier + table.

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
    test "transform bad_request details all map to 400" do
      assert {400, _} = ErrorStatus.resolve_status({:transform_error, {:bad_request, :upscale_required}})
      assert {400, _} = ErrorStatus.resolve_status({:transform_error, {:bad_request, :region_out_of_bounds}})
      assert {400, _} = ErrorStatus.resolve_status({:transform_error, {:bad_request, :anything}})
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
      # a host source adapter asserting a status with a custom detail atom
      assert {404, _} = ErrorStatus.resolve_status({:source, {:not_found, :my_detail}})
      # a render-wrapped source reason resolves via the inner reason
      assert {504, _} = ErrorStatus.resolve_status({:render, {:source, :receive_timeout}})
    end

    test "passthrough clamps an out-of-range code defensively" do
      assert {502, _} = ErrorStatus.resolve_status({:source, {:passthrough, 999}})
    end
  end

  describe "resolve_status/1 — message axis" do
    test "messages are distinct across reasons and never embed a URL" do
      reasons = [
        {:transform_error, {:bad_request, :upscale_required}},
        {:transform_error, {:bad_request, :region_out_of_bounds}},
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
          | {:passthrough, 100..599}

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
  defp class_lead({:passthrough, code}) when is_integer(code) and code in 400..499,
    do: {:passthrough, code}

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

  def message_for({:transform_error, {:bad_request, :region_out_of_bounds}}),
    do: "requested region is outside the image"

  def message_for({:transform_error, {:bad_request, _}}), do: "bad request"
  def message_for({:transform_error, _}), do: "invalid image transform"
  def message_for({:render, inner}), do: message_for(inner)
  def message_for({:source, {:bad_status, code}}), do: "upstream responded #{code}"
  def message_for({:source, :connect_error}), do: "source unreachable"
  def message_for({:source, :too_many_redirects}), do: "too many redirects"
  def message_for({:source, :redirect_not_followed}), do: "redirect not followed"
  def message_for({:source, :invalid_redirect}), do: "invalid redirect"
  def message_for({:source, :receive_timeout}), do: "source timeout"
  def message_for({:source, :body_too_large}), do: "source image is too large"

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
Expected: compiles; no Boundary violation (ErrorStatus is within the `Response` boundary and unexported — only same-boundary `Sender` and the test reference it; Boundary does not check `test/`).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/error_status.ex test/image_pipe/response/error_status_test.exs
git commit -m "Add Response.ErrorStatus classifier (reason -> {status, message})"
```

---

## Task 2: Route the transform/plan/decode side through `ErrorStatus` in `Sender`

Collapse the pure status clauses into one generic clause; thread `opts`. Keep the encode/cache/config/render-generic/exception paths (they log + 500).

**Files:**
- Modify: `lib/image_pipe/response/sender.ex`

- [ ] **Step 1: Thread `opts` into the error dispatch**

In `send_result/3`, the error clause currently drops `_opts`. Change it to pass `opts` through.

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

- [ ] **Step 3: Replace the pure-mapping clauses with one generic clause**

Delete these `handle_processing_error/3` clauses (they are subsumed by the generic clause + `ErrorStatus.classify`):
- the `{:transform_error, {:bad_request, _}}` clause (`sender.ex:135-142`)
- the `{:transform_error, reason}` clause (`:144-151`)
- the `{:source, error}` clause (`:153-154`) — **source is handled in Task 3 via `send_source_error`; remove this delegation**
- the `{:decode, error}` (`:156-157`), `{:unsupported_source_format, _}` (`:159-160`), `:source_format_required` (`:162-163`), `{:input_limit, error}` (`:165-166`) clauses
- the `{:unsupported_output_format, _}` clause (`:185-192`)
- the `{:render, {:decode,_}}`, `{:render, {:source,_}}`, `{:render, {:unsupported_source_format,_}}`, `{:render, :source_format_required}`, `{:render, {:input_limit,_}}` unwrap arms (`:194-215`) — `ErrorStatus.classify({:render, inner})` recurses, so these are redundant
- the `@plan_validation_error_tags` guarded clause (`:226-229`) and `send_plan_validation_error/3` (`:231-234`)
- `send_transform_error/2`, `send_bad_request_error/2`, `send_unsupported_output_format_error/2`, `send_decode_error/3`, `send_input_limit_error/3` private senders (now unused)

**Keep** (do not touch): `handle_encode_exception`, `{:encode, exception, stacktrace}` clause, `{:encode, :empty_stream}` clause, `{:cache_write, _}` clause + `send_cache_error`, `{:config, _}` clause + `send_config_error`, and the generic `{:render, reason}` → 500 clause (`:217-224`). These log and are server-side 500s.

Then add **one** generic `handle_processing_error/4` clause as the **last** clause (after the kept special clauses), and give the kept clauses a 4th `_opts` param. The kept clauses change arity 3 → 4 (add `_opts`); the delegations to `handle_encode_exception` etc. are unchanged otherwise.

New generic clause:

```elixir
  defp handle_processing_error(conn, reason, response_headers, opts) do
    {status, message} = ErrorStatus.resolve_status(reason, opts)

    Logger.info("processing_error: #{status} #{inspect(reason)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end
```

> `opts` is the same keyword `send_result/3` already receives (the request
> options). `ErrorStatus.resolve_status/2` ignores it today (Option A deferred);
> it is threaded purely so the future host policy is a one-spot addition. Pass it
> through verbatim.

Update the kept special clauses to arity 4 by adding `, _opts` to each head, e.g.:

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

  defp handle_processing_error(conn, {:render, reason}, response_headers, _opts) do
    Logger.error("render_error: #{inspect(reason)}")

    conn
    |> put_resp_headers(response_headers)
    |> put_resp_content_type("text/plain")
    |> send_resp(500, "error rendering response")
  end
```

Remove the now-unused `@plan_validation_error_tags` module attribute from `sender.ex` (it lives in `ErrorStatus` now).

- [ ] **Step 4: Run the existing wire suite as regression**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS. (Transform 422s, decode 415s, input-limit 413s, unsupported-output 501s, and the existing upscale 400 all still resolve identically through `ErrorStatus`.)

- [ ] **Step 5: Compile + format**

Run: `mise exec -- mix compile --warnings-as-errors && mise exec -- mix format`
Expected: clean; no unused-function warnings (all deleted senders removed).

- [ ] **Step 6: Commit**

```bash
git add lib/image_pipe/response/sender.ex
git commit -m "Route transform/plan/decode errors through ErrorStatus; thread opts"
```

---

## Task 3: Route source errors through `ErrorStatus` (both render sites) — #160

**Files:**
- Modify: `lib/image_pipe/response/sender.ex` (rewrite `send_source_error`)
- Modify: `lib/image_pipe/plug.ex:121-125` (pass `opts`)
- Test: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Write failing wire tests for source statuses**

In `test/image_pipe/imgproxy_wire_conformance_test.exs`, add a failing-origin plug near the other origin modules:

```elixir
  defmodule StatusOrigin do
    @moduledoc false
    # Returns whatever status the path's query asks for, e.g. ?status=503.
    def call(%Plug.Conn{} = conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)
      status = conn.query_params |> Map.get("status", "503") |> String.to_integer()
      Plug.Conn.send_resp(conn, status, "origin says #{status}")
    end
  end
```

Add these tests (use the established `RootHTTPAdapter` + `req_options: [plug: …]` pattern; the `@default_opts` / `call_imgproxy` helpers already exist in this file):

```elixir
  describe "source-fetch failures map to imgproxy-shaped statuses (#160)" do
    defp status_origin_opts do
      Keyword.merge(@default_opts,
        sources: [
          path: {RootHTTPAdapter, root_url: "http://origin.test", req_options: [plug: StatusOrigin]}
        ]
      )
    end

    test "upstream 5xx -> 502 bad gateway" do
      conn = call_imgproxy("/_/rs:fit:50:50/plain/images/x.jpg?status=503", status_origin_opts())
      assert conn.status == 502
      assert ["text/plain" <> _] = get_resp_header(conn, "content-type")
      assert conn.resp_body == "upstream responded 503"
    end

    test "upstream 4xx passes through (arbitrary code)" do
      conn = call_imgproxy("/_/rs:fit:50:50/plain/images/x.jpg?status=451", status_origin_opts())
      assert conn.status == 451
      assert conn.resp_body == "upstream responded 451"
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: FAIL on the two new tests — current code returns 422 "invalid image source" for both.

- [ ] **Step 3: Rewrite `send_source_error` to use `ErrorStatus`**

In `sender.ex`, replace the two `send_source_error` heads (`:98-108`) with a single `opts`-aware version:

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

> The third arg was `response_headers` before, but the only remaining caller (`plug.ex`, resolve-time) passes none, and the streaming source path now flows through the generic `handle_processing_error/4` clause (Task 2) which already applies `response_headers`. So `send_source_error/3`'s third arg becomes `opts`.

- [ ] **Step 4: Pass `opts` from `plug.ex`**

In `lib/image_pipe/plug.ex:121-125`, the source-error branch calls `Sender.send_source_error(conn, error)`. Change to thread `opts`:

Find:

```elixir
      {:error, {:source, error}} ->
        send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error) end)
```

Replace:

```elixir
      {:error, {:source, error}} ->
        send_response(conn, opts, :source_error, fn -> Sender.send_source_error(conn, error, opts) end)
```

- [ ] **Step 5: Run the new source-status tests + the full wire file**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`
Expected: PASS (new 502/451 tests green; existing tests still pass — the pre-existing 422 corrupt-source/etc. remain decode-class 415, not source).

- [ ] **Step 6: Compile + format, then commit**

```bash
mise exec -- mix compile --warnings-as-errors && mise exec -- mix format
git add lib/image_pipe/response/sender.ex lib/image_pipe/plug.ex test/image_pipe/imgproxy_wire_conformance_test.exs
git commit -m "Map source-fetch failures to imgproxy-shaped statuses via ErrorStatus (#160)"
```

---

## Task 4: New `:bad_request` producer — IIIF out-of-bounds region → 400

**Files:**
- Modify: `lib/image_pipe/transform/operation/crop.ex`
- Test: `test/parser/iiif_wire_test.exs`

- [ ] **Step 1: Write the failing IIIF wire test**

In `test/parser/iiif_wire_test.exs` (the `OriginImage` serves a 200×300 PNG; `call_iiif`/`iiif_opts` helpers exist), add near the other 400 tests (around `:437`):

```elixir
  test "region wholly outside the image -> 400" do
    # Source is 200×300; x=250 is past the right edge -> zero overlap.
    conn = call_iiif("/img/250,0,50,50/max/0/default.png", iiif_opts(OriginImage))
    assert conn.status == 400
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: FAIL on the new test — currently the region clamps to an edge strip (200) or surfaces `{Crop, _}` → 422, not 400.

- [ ] **Step 3: Detect the wholly-outside region in `crop.ex`**

In `lib/image_pipe/transform/operation/crop.ex`, the coordinate-region branch of `crop_coordinates/4` (`:270-288`) handles `crop_from` maps (gravity crops use the `:gravity` clause above it). Add an out-of-bounds guard at the top of that clause. `resolve_position/2` is already imported from `ImagePipe.Transform.Geometry`.

Find the clause head + body start (`:270-277`):

```elixir
  defp crop_coordinates(%__MODULE__{} = params, %State{}, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height
```

Replace with:

```elixir
  defp crop_coordinates(
         %__MODULE__{crop_from: %{left: from_left, top: from_top}} = params,
         %State{},
         image_width,
         image_height
       ) do
    left_px = resolve_position(from_left, image_width)
    top_px = resolve_position(from_top, image_height)

    if left_px >= image_width or top_px >= image_height do
      # A region whose origin is at/past the far edge has zero overlap with the
      # image and is unsatisfiable -> 400 (IIIF spec.md:192; shared neutral rule).
      {:error, {:bad_request, :region_out_of_bounds}}
    else
      do_region_crop_coordinates(params, image_width, image_height)
    end
  end

  defp do_region_crop_coordinates(%__MODULE__{} = params, image_width, image_height) do
    # keep :auto dimensions as is
    target_width = if params.width == :auto, do: image_width, else: params.width
    target_height = if params.height == :auto, do: image_height, else: params.height
```

(The remainder of the original body — `crop_width`/`crop_height`/`anchor_crop_to_pixels`/`left`/`top`/`{:ok, …}` — stays as the body of `do_region_crop_coordinates/3`, unchanged.)

- [ ] **Step 4: Pass the `:bad_request` error through `execute/2` unwrapped**

In `crop.ex` `execute/2` (`:202-213`), the catch-all wraps every error as `{__MODULE__, error}`. Pass a `:bad_request` reason through **unwrapped** so the chain tags it `{:transform_error, {:bad_request, _}}` (not nested under the module).

Find (`:206-212`):

```elixir
    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        crop_image(params, state, {left, top, crop_width, crop_height})

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
```

Replace with:

```elixir
    case crop_coordinates(params, state, image_width, image_height) do
      {:ok, %{left: left, top: top, width: crop_width, height: crop_height}} ->
        crop_image(params, state, {left, top, crop_width, crop_height})

      {:error, {:bad_request, _} = bad_request} ->
        {:error, bad_request}

      {:error, error} ->
        {:error, {__MODULE__, error}}
    end
```

- [ ] **Step 5: Run the IIIF test + the crop/transform suites**

Run: `mise exec -- mix test test/parser/iiif_wire_test.exs`
Expected: PASS (new 400 test green; existing IIIF region/200 tests unaffected — partial overlap still clips).

Run the crop/transform regression (gravity crops untouched; TwicPics region crops share this op):

Run: `mise exec -- mix test test/image_pipe/transform/ test/parser/twic_pics_test.exs test/parser/iiif_test.exs`
Expected: PASS. If a TwicPics test expected a wholly-outside region to clamp rather than 400, surface it — per the spec's cross-target flag, the final compat review decides whether OOB→400 must become parser-gated. Do **not** silently weaken the test; report it.

- [ ] **Step 6: Compile + format, then commit**

```bash
mise exec -- mix compile --warnings-as-errors && mise exec -- mix format
git add lib/image_pipe/transform/operation/crop.ex test/parser/iiif_wire_test.exs
git commit -m "Emit {:bad_request, :region_out_of_bounds} for wholly-outside region (IIIF 400)"
```

---

## Task 5: Conformance-matrix updates (behavioral axis)

**Files:**
- Modify: `docs/imgproxy_support_matrix.md`
- Modify: `docs/iiif_3_support_matrix.md`

- [ ] **Step 1: imgproxy matrix — source-fetch-failure status rows**

In `docs/imgproxy_support_matrix.md`, add/adjust the source-fetch-failure status mapping to reflect the realized behavior, parity-confirmed against the local imgproxy checkout (`/Users/hlindset/src/imgproxy`, `fetcher/errors.go` / `imagedata/errors.go`). Add a table like:

```markdown
### Source-fetch failure → HTTP status (behavioral, [#160](https://github.com/hlindset/image_pipe/issues/160))

| Fetch failure | ImagePipe | imgproxy | Parity |
| --- | --- | --- | --- |
| Unreachable / connect error | 404 | 404 (`fetcher/errors.go:37`) | ✅ |
| Too many redirects | 404 | 404 (`:109`) | ✅ |
| Upstream 4xx | passthrough that 4xx | passthrough (`:88-91`) | ✅ |
| Upstream 5xx | 502 | 502 (`:93`) | ✅ |
| Request timeout (per-message read) | 504 | 504 (`:131`) | ✅ |
| Oversized / incomplete body | 422 | 422 (`imagedata/errors.go:17`, `fetcher/errors.go:171`) | ✅ |

**Diverges (non-status):** error *body* copy is distinct per reason
(`upstream responded 503`, `source timeout`, …); imgproxy returns a single
uniform "Source is unreachable" string. Status (the wire-observable axis)
matches; body copy is a deliberate, product-neutral divergence. The 60s
wedged-session backstop stays 500 (internal stall, not source liveness; imgproxy's
*whole-request* timeout is 503). The pre-existing unsupported-output → 501 and
unsupported-source-format → 415 rows are unchanged ImagePipe divergences from
imgproxy's 422 and are **not** claimed as parity here.
```

- [ ] **Step 2: iiif matrix — OOB region row becomes truthful**

In `docs/iiif_3_support_matrix.md`, the region row (`:29`) and the runtime-error row (`:122`) already say wholly-out-of-bounds → 400; that is now actually realized (was 422). Update the "Status mapping" note to describe the general mechanism rather than the bespoke `Sender` clause, and add a forward note:

```markdown
> The runtime 400 for a wholly-out-of-bounds region and for no-`^` upscale is
> produced by the transform op emitting `{:bad_request, _}`, routed by
> `ImagePipe.Response.ErrorStatus` (the general error→status mechanism,
> [#267](https://github.com/hlindset/image_pipe/issues/267)). If a future
> deployment disables `^` upscaling, the correct status is **501** (Not
> Implemented, IIIF spec §size_up), expressed via the `:unsupported_output`
> class — **not** `:bad_request` → 400.
```

- [ ] **Step 3: Commit**

```bash
git add docs/imgproxy_support_matrix.md docs/iiif_3_support_matrix.md
git commit -m "Docs: source-status parity table (#160) + truthful IIIF OOB-region 400"
```

---

## Task 6: Final gate

- [ ] **Step 1: Run the Elixir gate**

Run: `mise run precommit`
Expected: `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, and `mix test` all green.

- [ ] **Step 2: Fix anything the gate surfaces, re-run, then commit any fixes**

If credo flags the new module (e.g. cyclomatic complexity on `classify`/`message_for` — they are flat pattern-match dispatch, which credo usually accepts; if not, no logic change, just satisfy the check), fix and re-run `mise run precommit`.

```bash
git add -A
git commit -m "Satisfy precommit gate for error-status mapping"
```

- [ ] **Step 3: Final review handoff**

Per the spec's execution recommendation, request one final parallel review of the complete diff with a **compatibility (imgproxy + IIIF + TwicPics) lens** — confirm the source-status table against `fetcher/errors.go` and that the shared `Crop` OOB→400 does not regress TwicPics (check `twicpics` docs + the differential suite). Use the `superpowers:requesting-code-review` skill.

---

## Self-review notes (coverage map)

- **Class vocabulary + status table** → Task 1 (`default_status_code`, `class_lead`, passthrough clamp).
- **Reason-keyed messages + distinctness/no-URL** → Task 1 (`message_for`, message-axis tests).
- **Custom reason atoms / class-leading routing** → Task 1 (`class_lead`, the class-leading test).
- **Total classification / unrecognized fallback** → Task 1 (`source_domain_class(_other)`, `classify(_other)`, the fallback test).
- **#267 transform unification + opts seam** → Task 2.
- **#160 source unification, both render sites** → Task 3 (generic clause + `send_source_error` rewrite + `plug.ex`).
- **`{:passthrough, code}` guard** → Task 1 (`default_status_code` floor) + Task 3 (4xx passthrough wire test).
- **New IIIF OOB producer** → Task 4.
- **Session backstop stays 500** → no code change (intentionally untouched); covered by not modifying `normalize_session_prepare_error/1`.
- **Matrices (behavioral axis)** → Task 5.
- **Final compat review (TwicPics non-regression)** → Task 6 Step 3.
