# Safety Default Limits Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add default source byte and static result dimension limits without changing unrelated parser, negotiation, metadata, or cache-header behavior.

**Architecture:** Request options own public limit validation and defaults. Source streams keep enforcing body bytes through `ImagePipe.Source.WrappedStream`. Request processing validates the decoded input first, executes product-neutral transforms, then rejects oversize final static image dimensions before final output resolution and encoding. Safety limits gate generation; they don't change representation identity or cache key material.

**Tech Stack:** Elixir, Plug, ExUnit, NimbleOptions, Boundary, ImagePipe request/source/output/cache/transform modules.

---

## Decisions

- Default `:max_body_bytes`: `10_000_000` bytes. This matches the development server example already in `lib/mix/tasks/image_pipe.server.ex`.
- Default result limits: `max_result_width: 8_192`, `max_result_height: 8_192`, and `max_result_pixels: 40_000_000`.
- Result dimension means the final static `Vix.Vips.Image` width, height, and `width * height` after transform execution and materialization, before final output resolution and encoding.
- Oversize results return HTTP `413` with `result image is too large`. The error reason should distinguish result limits as `{:result_limit, ...}` internally.
- Animation frame limits from issue #45 are intentionally out of scope.

## File Structure

Modify:

- `lib/image_pipe/request/options.ex`: validate/default `:max_body_bytes`, `:max_input_pixels`, `:max_result_width`, `:max_result_height`, and `:max_result_pixels`; pass only source runtime options to source adapters.
- `lib/image_pipe/source.ex`: require validated runtime opts to include `:max_body_bytes`.
- `lib/image_pipe/request/processor.ex`: consume validated `:max_input_pixels`; add final static result dimension validation after transform/materialization and before output resolution.
- `lib/image_pipe/request/source_session/producer.ex`: no behavior change beyond calling the processor path that now returns result-limit errors before `Encoder.stream_output/3`.
- `lib/image_pipe/response/sender.ex`: route `{:result_limit, reason}` to a result-specific HTTP 413 response with a distinct log tag.
- `lib/image_pipe/cache.ex`: keep request safety limits out of cache key construction.
- `lib/image_pipe/cache/key.ex`: keep cache identity based on source identity, plan, output negotiation, configured vary inputs, and cachebuster.
- `docs/operational_notes.md`: document defaults and the final-result validation boundary.
- `docs/imgproxy_support_matrix.md`: change only the safety-limit rows affected by this static-result slice.

Test:

- `test/image_pipe/request_options_test.exs`: option defaults, explicit overrides, and invalid values.
- `test/image_pipe/source_test.exs`: explicit source body limit at the source wrapping boundary.
- `test/image_pipe/processor_test.exs`: final result dimension limit unit coverage.
- `test/image_pipe/plug_test.exs`: wire-level body-limit defaults, explicit override, oversized result response, in-limit success, and pre-encode side-effect ordering.
- `test/image_pipe/cache/key_test.exs`: deterministic key material excludes request safety limits.

Don't change:

- Parser grammar or Imgproxy URL option order.
- Accept negotiation, automatic output format selection, EXIF autorotation, metadata handling, filters, or cache-header policy.
- Animation frame behavior.

## Task 1: Request Option Defaults and Source Body Limit

**Files:**

- Modify: `lib/image_pipe/request/options.ex`
- Modify: `lib/image_pipe/source.ex`
- Test: `test/image_pipe/request_options_test.exs`
- Test: `test/image_pipe/source_test.exs`

- [ ] **Step 1: Add failing option default tests**

Add to `test/image_pipe/request_options_test.exs`:

```elixir
test "request safety limits have defaults" do
  opts = Options.validate!(@base_opts)

  assert Keyword.fetch!(opts, :max_body_bytes) == 10_000_000
  assert Keyword.fetch!(opts, :max_input_pixels) == 40_000_000
  assert Keyword.fetch!(opts, :max_result_width) == 8_192
  assert Keyword.fetch!(opts, :max_result_height) == 8_192
  assert Keyword.fetch!(opts, :max_result_pixels) == 40_000_000
end

test "request safety limits accept explicit valid overrides" do
  opts =
    Options.validate!(
      Keyword.merge(@base_opts,
        max_body_bytes: 123,
        max_input_pixels: 456,
        max_result_width: 78,
        max_result_height: 90,
        max_result_pixels: 1_234
      )
    )

  assert Keyword.fetch!(opts, :max_body_bytes) == 123
  assert Keyword.fetch!(opts, :max_input_pixels) == 456
  assert Keyword.fetch!(opts, :max_result_width) == 78
  assert Keyword.fetch!(opts, :max_result_height) == 90
  assert Keyword.fetch!(opts, :max_result_pixels) == 1_234
end

test "request safety limits reject malformed values" do
  for {key, value} <- [
        max_body_bytes: 0,
        max_input_pixels: 0,
        max_result_width: 0,
        max_result_height: -1,
        max_result_pixels: "40MP"
      ] do
    assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
      Options.validate!(Keyword.put(@base_opts, key, value))
    end
  end
end
```

- [ ] **Step 2: Verify option tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/request_options_test.exs
```

Expected: the default and malformed-value tests fail. The explicit valid override test may pass before implementation because unknown top-level options currently pass through; after implementation, it proves these values are validated by the request option schema.

- [ ] **Step 3: Add failing source wrapping test**

Add to `test/image_pipe/source_test.exs`:

```elixir
test "wrap_response accepts explicit source body limit override" do
  body = :binary.copy("a", 10_000_001)
  response = %Response{stream: [body]}

  assert {:ok, %Response{} = wrapped} =
           Source.wrap_response(response, max_body_bytes: byte_size(body))

  assert Enum.to_list(wrapped.stream) == [body]
  refute Source.body_limit_exceeded?(wrapped)
end
```

Make sure `Source`, `Source.Response`, and `Source.StreamError` aliases/imports are present in that test module before adding the tests.

- [ ] **Step 4: Verify source tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/source_test.exs
```

Expected: the default-limit test fails because `Source.wrap_response/2` currently defaults to `:infinity`.

- [ ] **Step 5: Implement request defaults and source fallback**

In `lib/image_pipe/request/options.ex`, add module attributes and schema entries:

```elixir
@default_max_body_bytes 10_000_000
@default_max_input_pixels 40_000_000
@default_max_result_width 8_192
@default_max_result_height 8_192
@default_max_result_pixels 40_000_000
```

Add these keys to `@validated_option_keys`:

```elixir
:max_body_bytes,
:max_input_pixels,
:max_result_width,
:max_result_height,
:max_result_pixels
```

Add schema entries:

```elixir
max_body_bytes: [type: :pos_integer, default: @default_max_body_bytes],
max_input_pixels: [type: :pos_integer, default: @default_max_input_pixels],
max_result_width: [type: :pos_integer, default: @default_max_result_width],
max_result_height: [type: :pos_integer, default: @default_max_result_height],
max_result_pixels: [type: :pos_integer, default: @default_max_result_pixels],
```

Keep `@source_runtime_option_keys` limited to source runtime behavior:

```elixir
@source_runtime_option_keys [
  :max_body_bytes,
  :receive_timeout,
  :connect_timeout,
  :pool_timeout,
  :request_id,
  :telemetry_prefix
]
```

In `lib/image_pipe/source.ex`, replace the fallback:

```elixir
max_body_bytes = Keyword.fetch!(runtime_opts, :max_body_bytes)
```

- [ ] **Step 6: Verify Task 1**

Run:

```bash
mise exec -- mix test test/image_pipe/request_options_test.exs test/image_pipe/source_test.exs
```

Expected: pass.

## Task 2: Static Result Dimension Limit

**Files:**

- Modify: `lib/image_pipe/request/processor.ex`
- Modify: `lib/image_pipe/response/sender.ex`
- Test: `test/image_pipe/processor_test.exs`
- Test: `test/image_pipe/plug_test.exs`

- [ ] **Step 1: Add failing processor result-limit tests**

Add to `test/image_pipe/processor_test.exs`:

```elixir
defp request_opts(overrides \\ []) do
  opts()
  |> Keyword.merge(
    parser: ImagePipe.Parser.Imgproxy,
    max_body_bytes: 10_000_000,
    max_input_pixels: 40_000_000,
    max_result_width: 8_192,
    max_result_height: 8_192,
    max_result_pixels: 40_000_000
  )
  |> Keyword.merge(overrides)
end

test "process_source rejects final images wider than configured result limit" do
  {:ok, operation} = Operation.resize(:fit, {:px, 21}, :auto, enlargement: :allow)

  plan = %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}

  assert {:error, {:result_limit, {:result_width_too_large, 21, 20}}} =
           Processor.process_source(
             plan,
             resolved_source(),
             request_opts(
               max_result_width: 20,
               max_result_height: 10_000,
               max_result_pixels: 10_000
             )
           )
end

test "process_source accepts final images within configured result limits" do
  {:ok, operation} = Operation.resize(:fit, {:px, 20}, :auto, enlargement: :allow)

  plan = %Plan{plan() | pipelines: [%Pipeline{operations: [operation]}]}

  assert {:ok, %State{} = state} =
           Processor.process_source(
             plan,
             resolved_source(),
             request_opts(
               max_result_width: 20,
               max_result_height: 20,
               max_result_pixels: 400
             )
           )

  assert Image.width(state.image) <= 20
  assert Image.height(state.image) <= 20
end
```

If `request_opts/1` would duplicate an existing helper, merge the default limit fields into the existing helper instead. Existing direct processor tests should also use request defaults before `Processor.process_source/3` or `Processor.decode_validate_source_response/3` calls that rely on validated limit options.

- [ ] **Step 2: Verify processor tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/processor_test.exs
```

Expected: first new test returns `{:ok, %State{}}` instead of a result-limit error.

- [ ] **Step 3: Add failing Plug result-limit tests**

Add to `test/image_pipe/plug_test.exs` near the existing input/body limit tests:

```elixir
test "rejects static result dimensions above configured limits before encoding" do
  conn =
    conn(:get, "/_/el:1/w:64/f:jpeg/plain/images/beach.jpg")
    |> call_image_pipe(
      root_url: "http://origin.test",
      parser: ImagePipe.Parser.Imgproxy,
      max_result_width: 32,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000,
      image_module: StreamingOnlyImage,
      cache: {CacheProbe, message_target: self()},
      origin_req_options: [plug: CountingOriginImage, test_pid: self()]
    )

  assert conn.status == 413
  assert conn.resp_body == "result image is too large"
  assert_received {:cache_get, _key}
  assert_received :origin_was_called
  refute_received :stream_encoder_called
  refute_received {:cache_put, _key, _entry}
end

test "allows static result dimensions within configured limits" do
  conn =
    conn(:get, "/_/el:1/w:64/f:jpeg/plain/images/beach.jpg")
    |> call_image_pipe(
      root_url: "http://origin.test",
      parser: ImagePipe.Parser.Imgproxy,
      max_result_width: 64,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000,
      image_module: StreamingOnlyImage,
      origin_req_options: [plug: OriginImage]
    )

  assert conn.status == 200
  assert conn.resp_body == "streamed jpeg"
  assert_received :stream_encoder_called
end
```

- [ ] **Step 4: Verify Plug tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/plug_test.exs
```

Expected: the oversized result test currently encodes and returns `200`.

This test pins the intended ordering: parser and plan validation have already passed, cache lookup may happen before source fetch, the source is fetched so the final dimensions can be known, and the result-limit failure happens before encoder or cache-write side effects.

- [ ] **Step 5: Implement processor validation**

In `lib/image_pipe/request/processor.ex`, add a validation step after `materialize_before_delivery/4`:

```elixir
with {:ok, final_state} <-
       execute_plan_pipelines(%State{image: image}, plan, opts, source_response),
     {:ok, final_state} <-
       materialize_before_delivery(final_state, decode_options, opts, source_response),
     :ok <- validate_result_image(final_state.image, opts) do
  {:ok, final_state}
end
```

Add helpers:

```elixir
defp validate_result_image(image, opts) do
  width = Image.width(image)
  height = Image.height(image)
  pixels = width * height

  with :ok <- check_result_width(width, Keyword.fetch!(opts, :max_result_width)),
       :ok <- check_result_height(height, Keyword.fetch!(opts, :max_result_height)),
       :ok <- check_result_pixels(pixels, Keyword.fetch!(opts, :max_result_pixels)) do
    :ok
  end
end

defp check_result_width(width, max_width) when width <= max_width, do: :ok
defp check_result_width(width, max_width), do: {:error, {:result_limit, {:result_width_too_large, width, max_width}}}

defp check_result_height(height, max_height) when height <= max_height, do: :ok
defp check_result_height(height, max_height), do: {:error, {:result_limit, {:result_height_too_large, height, max_height}}}

defp check_result_pixels(pixels, max_pixels) when pixels <= max_pixels, do: :ok
defp check_result_pixels(pixels, max_pixels), do: {:error, {:result_limit, {:too_many_result_pixels, pixels, max_pixels}}}
```

Keep the existing input limit behavior unchanged except for reading the validated default with `Keyword.fetch!/2`. Unit tests that bypass `ImagePipe.Plug.init/1` must pass the same defaults through their helper.

- [ ] **Step 6: Implement sender routing**

In `lib/image_pipe/response/sender.ex`, add:

```elixir
defp handle_processing_error(conn, {:result_limit, error}, response_headers),
  do: send_result_limit_error(conn, error, response_headers)
```

and:

```elixir
defp send_result_limit_error(%Plug.Conn{} = conn, error, response_headers) do
  Logger.info("result_limit_error: #{inspect(error)}")

  conn
  |> put_resp_headers(response_headers)
  |> put_resp_content_type("text/plain")
  |> send_resp(413, "result image is too large")
end
```

- [ ] **Step 7: Verify Task 2**

Run:

```bash
mise exec -- mix test test/image_pipe/processor_test.exs test/image_pipe/plug_test.exs
```

Expected: pass.

## Task 3: Cache Key Determinism for Safety Limits

**Files:**

- Modify: `lib/image_pipe/cache.ex`
- Modify: `lib/image_pipe/cache/key.ex`
- Test: `test/image_pipe/cdn_http_cache_wire_test.exs`
- Test: `test/image_pipe/cache/key_test.exs`

- [ ] **Step 1: Add failing cache-key unit test**

Add to `test/image_pipe/cache/key_test.exs`:

```elixir
test "cache key material excludes request safety limits" do
  conn = conn(:get, "/_/w:100/plain/images/cat.jpg")

  default_key =
    build_key!(
      conn,
      plan(),
      source_identity(),
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000,
      max_result_width: 8_192,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    )

  strict_key =
    build_key!(
      conn,
      plan(),
      source_identity(),
      max_body_bytes: 1_000_000,
      max_input_pixels: 1_000_000,
      max_result_width: 256,
      max_result_height: 256,
      max_result_pixels: 65_536
    )

  refute Keyword.has_key?(default_key.data, :request_limits)
  assert default_key.hash == strict_key.hash
end
```

- [ ] **Step 2: Add failing cache forwarding and ETag tests**

Add to `test/image_pipe/cache/key_test.exs`:

```elixir
test "cache lookup key is independent of request safety limits" do
  conn = conn(:get, "/_/w:100/plain/images/cat.jpg")
  plan = plan()
  identity = source_identity()

  loose =
    ImagePipe.Cache.lookup(conn, plan, identity,
      cache: {ForwardingProbe, test_pid: self()},
      max_body_bytes: 10_000_000,
      max_input_pixels: 40_000_000,
      max_result_width: 8_192,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    )

  assert {:miss, %Key{} = loose_key} = loose

  strict =
    ImagePipe.Cache.lookup(conn, plan, identity,
      cache: {ForwardingProbe, test_pid: self()},
      max_body_bytes: 1_000_000,
      max_input_pixels: 1_000_000,
      max_result_width: 256,
      max_result_height: 256,
      max_result_pixels: 65_536
    )

  assert {:miss, %Key{} = strict_key} = strict
  assert loose_key.hash == strict_key.hash
  refute Keyword.has_key?(loose_key.data, :request_limits)
end
```

Add a minimal cache adapter in the same test module if one isn't already available:

```elixir
defmodule ForwardingProbe do
  @behaviour ImagePipe.Cache

  def get(_key, _opts), do: :miss
  def open_sink(_key, _metadata, _opts), do: raise("not used")
  def write_chunk(_state, _chunk, _opts), do: raise("not used")
  def commit_sink(_state, _opts), do: raise("not used")
  def abort_sink(_state, _opts), do: :ok
end
```

Add to `test/image_pipe/cdn_http_cache_wire_test.exs`:

```elixir
test "stricter result limit does not change generated etag", %{opts: opts} do
  loose =
    ImagePipe.Plug.call(
      conn(:get, "/_/el:1/w:64/f:jpeg/plain/beach.jpg"),
      Keyword.merge(opts,
        max_result_width: 64,
        max_result_height: 8_192,
        max_result_pixels: 40_000_000
      )
    )

  assert loose.status == 200
  assert [etag] = get_resp_header(loose, "etag")
  flush_messages()

  strict_opts =
    Keyword.merge(opts,
      max_result_width: 32,
      max_result_height: 8_192,
      max_result_pixels: 40_000_000
    )

  strict =
    :get
    |> conn("/_/el:1/w:64/f:jpeg/plain/beach.jpg")
    |> put_req_header("if-none-match", etag)
    |> ImagePipe.Plug.call(strict_opts)

  assert strict.status == 304
  assert strict.resp_body == ""
  assert get_resp_header(strict, "etag") == [etag]
  refute_received {:cache_get, %Key{}}
  refute_received :source_fetch_called
end
```

Limits gate response generation. If a successful representation already exists
and the conditional request matches its ETag, ImagePipe can return `304` without
regenerating under stricter limits.

- [ ] **Step 3: Verify cache-key and ETag tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected before the correction: `request_limits` is present, limit changes produce different keys, and stricter result limits can force regeneration instead of `304`.

- [ ] **Step 4: Keep safety limits out of key data**

In `lib/image_pipe/cache.ex`, keep `@plan_key_option_keys` limited to representation-affecting output options:

```elixir
@plan_key_option_keys [
  :auto_avif,
  :auto_webp
]
```

In `lib/image_pipe/cache/key.ex`, don't append `request_limits` to key material.
Keep `schema_version`, `transform` version, and `representation` version unchanged.

- [ ] **Step 5: Verify Task 3**

Run:

```bash
mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: pass.

## Task 4: Wire Tests for Source Body Default and Side-Effect Ordering

**Files:**

- Modify: `test/image_pipe/plug_test.exs`
- Modify: `test/image_pipe/request_safety_test.exs` if the focused tests fit better there.

- [ ] **Step 1: Add failing Plug body-limit tests**

Add helper modules to `test/image_pipe/plug_test.exs` near existing origin helpers:

```elixir
defmodule LargeBodyOrigin do
  def call(conn, _opts) do
    body = :binary.copy("a", 10_000_001)

    conn
    |> Plug.Conn.put_resp_content_type("image/jpeg")
    |> Plug.Conn.send_resp(200, body)
  end
end

defmodule ConsumeSourceThenDecodeErrorImage do
  def open(stream, _decode_options) do
    _ = Enum.to_list(stream)
    {:error, :forced_decode_error}
  end
end
```

Add tests near existing body-limit tests:

```elixir
test "default source body limit applies through the request flow" do
  conn =
    conn(:get, "/_/plain/images/large-body.jpg")
    |> call_image_pipe(
      root_url: "http://origin.test",
      parser: ImagePipe.Parser.Imgproxy,
      image_open_module: ConsumeSourceThenDecodeErrorImage,
      origin_req_options: [plug: LargeBodyOrigin]
    )

  assert conn.status == 422
  assert conn.resp_body == "invalid image source"
end

test "explicit source body limit overrides the default through the request flow" do
  conn =
    conn(:get, "/_/plain/images/large-body.jpg")
    |> call_image_pipe(
      root_url: "http://origin.test",
      parser: ImagePipe.Parser.Imgproxy,
      max_body_bytes: 10_000_001,
      image_open_module: ConsumeSourceThenDecodeErrorImage,
      origin_req_options: [plug: LargeBodyOrigin]
    )

  assert conn.status == 415
  assert conn.resp_body == "source response is not a supported image"
end
```

The first test proves the non-bang request flow returns the source error caused by the body limit. The second proves explicit config lets the fake decoder consume the body and return its normal decode error.

- [ ] **Step 2: Verify Plug body-limit tests fail**

Run:

```bash
mise exec -- mix test test/image_pipe/plug_test.exs
```

Expected: the default-limit test returns the fake decode error until Task 1 is implemented.

- [ ] **Step 3: Re-run focused Plug coverage**

Run:

```bash
mise exec -- mix test test/image_pipe/plug_test.exs
```

Expected: pass after Tasks 1 and 2.

## Task 5: Docs

**Files:**

- Modify: `docs/operational_notes.md`
- Modify: `docs/imgproxy_support_matrix.md`

- [ ] **Step 1: Update operational notes**

Replace this sentence in `docs/operational_notes.md`:

```markdown
HTTP and S3 source fetches use non-bang Req calls with bounded redirects and
receive timeouts. ImagePipe reads the source format from the decoded image
rather than trusted HTTP headers. Configure byte and decode limits with
`:max_body_bytes` and `:max_input_pixels`.
```

with:

```markdown
HTTP and S3 source fetches use non-bang Req calls with bounded redirects and
receive timeouts. ImagePipe reads the source format from the decoded image
rather than trusted HTTP headers. `:max_body_bytes` defaults to `10_000_000`
bytes. `:max_input_pixels` defaults to `40_000_000` decoded pixels. Override
both in `ImagePipe.Plug` init options.

Static result limits run after transform execution and before final output
resolution or encoding. `:max_result_width` and `:max_result_height` default
to `8_192`; `:max_result_pixels` defaults to `40_000_000`. Result dimensions
mean the final static image width, height, and pixel count. Animation frame
count limits stay out of this slice.
```

- [ ] **Step 2: Update Imgproxy support matrix**

Replace the `Input and output safety limits` paragraph in `docs/imgproxy_support_matrix.md` with:

```markdown
Top-level `max_body_bytes` caps fetched source bodies and defaults to
`10_000_000` bytes. Cache adapter `max_body_bytes` still caps encoded response
staging for adapters that configure it. ImagePipe uses `max_input_pixels` for
decoded input size and `max_result_width`, `max_result_height`, and
`max_result_pixels` for final static result size. It doesn't expose Imgproxy's
animation, SVG, or PNG-specific policy.
```

Leave the `IMGPROXY_MAX_RESULT_DIMENSION` row marked missing. This PR adds
host request options for final static result limits. It doesn't add imgproxy
URL/config compatibility for `max result dimension`.

```markdown
- ⭕ `IMGPROXY_MAX_RESULT_DIMENSION`
```

Don't mark animation rows as supported.

## Task 6: Final Verification

**Files:**

- No new files.

- [ ] **Step 1: Run focused tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request_options_test.exs test/image_pipe/source_test.exs test/image_pipe/processor_test.exs test/image_pipe/plug_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: pass.

- [ ] **Step 2: Run the full suite**

Run:

```bash
mise exec -- mix test
```

Expected: pass.

- [ ] **Step 3: Run warnings-as-errors compile**

Run:

```bash
mise exec -- mix compile --warnings-as-errors
```

Expected: pass.

## Plan Self-Review

- Spec coverage: Tasks 1 and 4 cover issue #9 default source body limit. Tasks 2, 3, and 5 cover the static result-dimension slice of issue #45. Animation frame limits stay out of scope.
- Side-effect ordering: parser and planner validation remain before source and cache work. Result limit validation happens after transforms because the exact final static dimensions are known there, and before final output resolution or encoding. Cache keys and generated ETags stay tied to representation identity; safety limits decide whether a miss may generate a new response.
- Placeholder scan: no task contains TBD, generic placeholder work, or undefined helper names.
- Type consistency: option names are `:max_body_bytes`, `:max_input_pixels`, `:max_result_width`, `:max_result_height`, and `:max_result_pixels` across tests, implementation, and docs.
