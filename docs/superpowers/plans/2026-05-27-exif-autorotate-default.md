# EXIF Autorotation Default Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to apply this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add imgproxy-compatible default autorotation config while preserving URL-level `auto_rotate` behavior.

**Architecture:** Keep autorotation in imgproxy parser request state, then translate it to `ImagePipe.Plan.Operation.AutoOrient` before crop and resize. Transform execution lowers that semantic Plan operation to `ImagePipe.Transform.Operation.AutoOrient` after cache lookup. Add the default in imgproxy parser/options config so request/source/response code continues to see only `ImagePipe.Plan`.

**Tech Stack:** Elixir, ExUnit, Plug test requests, NimbleOptions.

---

### Task 1: Parser config and precedence

**Files:**
- Change: `lib/image_pipe/parser/imgproxy.ex`
- Change: `lib/image_pipe/parser/imgproxy/options.ex`
- Test: `test/parser/imgproxy_test.exs`

- [ ] **Step 1: Write failing parser tests**

Add tests near the existing orientation parser assertions:

```elixir
test "imgproxy auto_rotate default applies when URL omits orientation" do
  opts = [imgproxy: [auto_rotate: true]]

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%AutoOrient{}]}]}} =
           Imgproxy.parse(conn(:get, "/_/plain/images/cat.jpg"), opts)
end

test "URL auto_rotate overrides the imgproxy default" do
  opts = [imgproxy: [auto_rotate: true]]

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: []}]}} =
           Imgproxy.parse(conn(:get, "/_/ar:false/plain/images/cat.jpg"), opts)

  assert {:ok, %Plan{pipelines: [%Pipeline{operations: [%AutoOrient{}]}]}} =
           Imgproxy.parse(conn(:get, "/_/ar:true/plain/images/cat.jpg"), opts)
end
```

- [ ] **Step 2: Run parser tests and confirm failure**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`

Expected: tests fail because `:auto_rotate` isn't accepted or applied.

- [ ] **Step 3: Add config/default handling**

Add `auto_rotate: [type: :boolean, default: true]` to the imgproxy NimbleOptions schema and add validation coverage for accepted booleans and a rejected non-boolean value.

Change `Options.parse/2` to `Options.parse/3`, with a default keyword list for callers that only pass presets. Add `auto_rotate_requested: false` to `PipelineRequest` and set it only when parsed URL assignments contain `auto_orient`.

After parsing and finalizing pipelines, apply `auto_rotate: true` to the first pipeline only when no URL pipeline explicitly requested `auto_rotate`/`ar`. This models the config as a request default applied once before processing. URL `ar:false` anywhere in the request suppresses the default. `rotate` and `flip` don't suppress it.

In `ImagePipe.Parser.Imgproxy.parse_request/2`, pass `[auto_rotate: Keyword.get(imgproxy_opts, :auto_rotate, false)]` into `Options.parse/3`.

Keep URL precedence in `update_current_pipeline/2`: parsed `orientation` assignments update the existing orientation struct and set `orientation_requested: true`. Parsed `auto_rotate` also sets `auto_rotate_requested: true`.

- [ ] **Step 4: Run parser tests**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs`

Expected: pass.

- [ ] **Step 5: Run focused validation tests**

Run: `mise exec -- mix test test/image_pipe/request_options_test.exs test/parser/imgproxy_test.exs`

Expected: pass.

### Task 2: Wire-Level Orientation Behavior

**Files:**
- Change: `test/image_pipe/imgproxy_wire_conformance_test.exs`

- [ ] **Step 1: Write failing wire tests**

Add a small test-only origin plug in the test module that returns an in-memory JPEG with EXIF orientation `6`. Assert a real `ImagePipe.Plug.call/2` request rotates by default config, URL `ar:true` still rotates without config, and URL `ar:false` disables the configured default.

Use generated image bytes instead of adding a fixture file:

```elixir
defmodule ExifOrientationOriginImage do
  @moduledoc false

  def call(conn, _opts) do
    body =
      40
      |> Image.new!(80, color: :white)
      |> Image.Draw.rect!(0, 0, 40, 40, color: :red)
      |> Image.set_orientation!(6)
      |> Image.write!(:memory, suffix: ".jpg")

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end
```

Expected decoded dimensions:
- configured `imgproxy: [auto_rotate: true]` and no URL `ar`: `{80, 40}`
- no config and URL `ar:true`: `{80, 40}`
- configured default plus URL `ar:false`: `{40, 80}`

- [ ] **Step 2: Run wire tests and confirm failure**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`

Expected: configured-default case fails before implementation. URL-level case should already pass.

- [ ] **Step 3: Make implementation adjustments if the parser-level change was incomplete**

Keep all behavior in parser/options/plan translation. Don't change source limits, result limits, output negotiation, metadata stripping, filters, cache headers, or request/source/response transform dispatch.

- [ ] **Step 4: Run wire tests**

Run: `mise exec -- mix test test/image_pipe/imgproxy_wire_conformance_test.exs`

Expected: pass.

### Task 3: Docs And Verification

**Files:**
- Change: `docs/imgproxy_path_api.md`
- Change: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update public docs**

Document `imgproxy: [auto_rotate: true | false]`, state the default is `true`, and state URL `ar:true`/`ar:false` overrides the configured default.

- [ ] **Step 2: Run focused tests**

Run: `mise exec -- mix test test/parser/imgproxy_test.exs test/image_pipe/imgproxy_wire_conformance_test.exs`

Expected: pass.

- [ ] **Step 3: Run compile verification**

Run: `mise exec -- mix compile --warnings-as-errors`

Expected: pass.

