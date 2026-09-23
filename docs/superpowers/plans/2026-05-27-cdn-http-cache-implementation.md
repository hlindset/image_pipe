# CDN HTTP Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add v1 CDN-facing HTTP cache support with generated `Cache-Control`, strong pre-fetch `ETag`, `Vary: Accept`, and `If-None-Match` handling for explicitly cacheable public image routes.

**Architecture:** Source adapters expose byte-identity semantics during `Source.resolve/3`. `ImagePipe.Plug` prepares HTTP cache headers after source resolution and before `Runner.run/4`, so matching conditional requests can return `304` before internal cache lookup or source fetch. Runner and Sender receive the prepared value for normal `200` delivery so cache misses and internal cache hits merge generated headers through the same path.

**Tech Stack:** Elixir, Plug, ExUnit, NimbleOptions, StreamData, Boundary, ImagePipe source/request/cache/output/response modules.

---

## File Structure

Create:

- `lib/image_pipe/source/cache_semantics.ex`: source-owned byte identity struct with enforced fields.
- `lib/image_pipe/request/http_cache.ex`: HTTP cache preparation, ETag material, `If-None-Match` parsing, `Vary` merge helpers, and direct `304` sender.
- `lib/image_pipe/response/cache_headers.ex`: response-owned prepared header bundle passed through Runner delivery without making `ImagePipe.Response` depend on `ImagePipe.Request`.
- `test/image_pipe/request/http_cache_test.exs`: unit coverage for prepared headers, ETags, `Vary`, conditional matching, serialization, and telemetry metadata.
- `test/image_pipe/cdn_http_cache_wire_test.exs`: Plug-level v1 behavior with real requests, source probes, cache probes, and cache-hit parity.

Modify:

- `lib/image_pipe/source.ex`: export `CacheSemantics`; validate `Resolved.internal_cache` and `cache_semantics`.
- `lib/image_pipe/source/resolved.ex`: replace `cache` with `internal_cache`; add `http_cache` and `cache_semantics` enforced fields.
- `lib/image_pipe/source/file.ex`: validate `stable`, `internal_cache`, and `http_cache`; set default not-stable source semantics.
- `lib/image_pipe/source/http.ex`: validate `stable`, `internal_cache`, and `http_cache`; migrate cache field usage to internal cache; avoid raw signed query material in byte identity.
- `lib/image_pipe/source/s3.ex`: validate `stable`, `internal_cache`, and `http_cache`; mark versioned objects stable under `stable: :auto`.
- `lib/image_pipe/request/options.ex`: add `http_cache: [mode: :disabled]` validation and keep parser-visible/runtime option boundaries unchanged.
- `lib/image_pipe/request/runner.ex`: accept prepared HTTP cache value and return it in cache-hit and prepared-stream delivery tuples; switch `cache` pattern matches to `internal_cache`.
- `lib/image_pipe/response/sender.ex`: merge prepared representation/cache headers into cached-entry and prepared-stream responses; preserve current host policy.
- `lib/image_pipe/response.ex`: export `CacheHeaders`.
- `lib/image_pipe/cache/key.ex`: include the HTTP cache representation version in internal cache key material.
- `lib/image_pipe/plan.ex`: export canonical representation material helper if implemented in a new plan module or directly here.
- `lib/image_pipe/output/policy.ex`: expose only the output data needed by canonical representation material if the plan layer can't derive it directly.
- `lib/image_pipe.ex`: update Boundary exports if new public/internal modules require it through existing top-level boundaries.
- `test/image_pipe/source/file_test.exs`, `test/image_pipe/source/http_test.exs`, `test/image_pipe/source/s3_test.exs`, `test/image_pipe/source_test.exs`: source semantics and migration coverage.
- `test/image_pipe/request_runner_test.exs`: delivery tuple and internal cache behavior.
- `test/image_pipe/response_sender_test.exs`: header merge behavior on cache hits and prepared streams.
- `test/image_pipe/cache/key_test.exs`, `test/image_pipe/cache/key_property_test.exs`: representation version in internal key material.
- `test/image_pipe/output_policy_test.exs` or `test/image_pipe/plan_test.exs`: canonical representation material.
- `test/image_pipe/request_options_test.exs`: `http_cache` option validation.
- `test/image_pipe/architecture_boundary_test.exs`: request/source/response/cache boundary updates.
- `README.md` or a new focused doc under `docs/`: user-facing CDN setup, source stability configuration, and ETag schema bump notes.

Don't modify:

- `ImagePipe.Cache.Entry.cacheable_headers/1` allowlist for `vary` or `cache-control`; it already allows both.
- Parser/provider modules to set response cache policy. Parser fields such as `Plan.expires` remain request validity/cache-key inputs only.

## Constants

Use implementation constants, not request options:

```elixir
@etag_schema 1
@representation_version 1
@generated_cache_control "public, max-age=31536000, immutable"
```

Build visible generated ETags from the schema constant:

```elixir
~s("ip#{@etag_schema}-#{Base.url_encode64(hash, padding: false)}")
```

The same `@representation_version` value must appear in generated ETag material and internal cache key material.

## Task 1: Source Cache Semantics and Resolved Migration

**Files:**

- Create: `lib/image_pipe/source/cache_semantics.ex`
- Modify: `lib/image_pipe/source.ex`
- Modify: `lib/image_pipe/source/resolved.ex`
- Modify: `lib/image_pipe/source/file.ex`
- Modify: `lib/image_pipe/source/http.ex`
- Modify: `lib/image_pipe/source/s3.ex`
- Test: `test/image_pipe/source_test.exs`
- Test: `test/image_pipe/source/file_test.exs`
- Test: `test/image_pipe/source/http_test.exs`
- Test: `test/image_pipe/source/s3_test.exs`
- Test: `test/image_pipe/request_runner_test.exs`

- [ ] **Step 1: Write the failing struct tests**

Add these tests to `test/image_pipe/source_test.exs`:

```elixir
defmodule ImagePipe.SourceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Source
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  test "cache semantics requires explicit byte identity and stability" do
    assert_raise ArgumentError, fn ->
      struct!(CacheSemantics, byte_identity: :none)
    end

    assert %CacheSemantics{byte_identity: :none, stable?: false} =
             struct!(CacheSemantics, byte_identity: :none, stable?: false)
  end

  test "resolved source requires internal cache mode, http cache mode, and cache semantics" do
    assert_raise ArgumentError, fn ->
      struct!(Resolved,
        adapter: :path,
        source_kind: :path,
        identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
        internal_cache: :disabled,
        fetch: [path: "/tmp/cat.jpg"]
      )
    end

    assert %Resolved{
             internal_cache: :disabled,
             http_cache: :inherit,
             cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}
           } =
             struct!(Resolved,
               adapter: :path,
               source_kind: :path,
               identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
               internal_cache: :disabled,
               http_cache: :inherit,
               cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false},
               fetch: [path: "/tmp/cat.jpg"]
             )
  end

  test "source validation rejects resolved values without cache semantics" do
    defmodule MissingSemanticsSource do
      @behaviour ImagePipe.Source

      def validate_options(opts), do: {:ok, opts}

      def resolve(%SourcePath{}, _opts, _runtime_opts) do
        {:ok,
         %Resolved{
           adapter: :path,
           source_kind: :path,
           identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
           internal_cache: :disabled,
           http_cache: :inherit,
           cache_semantics: nil,
           fetch: [path: "/tmp/cat.jpg"]
         }}
      end

      def fetch(_resolved, _opts, _runtime_opts), do: raise("not used")
    end

    opts = [
      parser: ImagePipe.Parser.Imgproxy,
      sources: [path: {MissingSemanticsSource, []}]
    ]

    source = %SourcePath{segments: ["cat.jpg"]}

    assert {:error, {:source, :invalid_adapter_result}} = Source.resolve(source, opts, [])
  end

end
```

If `test/image_pipe/source_test.exs` already has module content, merge these tests into that module instead of creating a duplicate `defmodule`.

- [ ] **Step 2: Run the struct tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/source_test.exs
```

Expected: fail because `ImagePipe.Source.CacheSemantics` doesn't exist and `Source.Resolved` still uses `cache`.

- [ ] **Step 3: Write failing source adapter behavior tests**

Add to `test/image_pipe/source/file_test.exs`:

```elixir
test "file source defaults to not stable and disables internal cache in auto mode", %{root: root} do
  assert {:ok, opts} = SourceFile.validate_options(root: root, root_id: "fixture-root")
  source = %SourcePath{segments: ["images", "cat.jpg"]}

  assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

  assert resolved.internal_cache == :disabled
  assert resolved.http_cache == :inherit
  assert resolved.cache_semantics.stable? == false
  assert resolved.cache_semantics.byte_identity == :none
end

test "file source trusted stability derives strong byte identity", %{root: root} do
  assert {:ok, opts} =
           SourceFile.validate_options(root: root, root_id: "fixture-root", stable: :trusted)

  source = %SourcePath{segments: ["images", "cat.jpg"]}

  assert {:ok, resolved} = SourceFile.resolve(source, opts, [])

  assert resolved.internal_cache == :enabled
  assert resolved.cache_semantics.stable? == true
  assert {:strong, seed} = resolved.cache_semantics.byte_identity
  assert seed[:root] == "fixture-root"
  assert seed[:path] == ["images", "cat.jpg"]
end
```

Add to `test/image_pipe/source/http_test.exs`:

```elixir
test "http source defaults to not stable and disables internal cache in auto mode" do
  assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"])
  source = %URL{scheme: :https, host: "example.com", path: ["cat.jpg"]}

  assert {:ok, resolved} = HTTP.resolve(source, opts, [])

  assert resolved.internal_cache == :disabled
  assert resolved.cache_semantics.byte_identity == :none
end

test "http trusted byte identity doesn't expose raw query" do
  assert {:ok, opts} = HTTP.validate_options(allowed_hosts: ["example.com"], stable: :trusted)

  source = %URL{
    scheme: :https,
    host: "example.com",
    path: ["cat.jpg"],
    query: "X-Amz-Signature=secret"
  }

  assert {:ok, resolved} = HTTP.resolve(source, opts, [])
  assert {:strong, seed} = resolved.cache_semantics.byte_identity
  refute inspect(seed) =~ "X-Amz-Signature=secret"
  assert is_binary(seed[:query_sha256])
end
```

Add to `test/image_pipe/source/s3_test.exs`:

```elixir
test "s3 revision is stable under auto mode" do
  assert {:ok, opts} =
           S3.validate_options(
             default: [
               region: "us-east-1",
               endpoint: "https://s3.amazonaws.com",
               credentials: {:static, access_key_id: "A", secret_access_key: "S"}
             ]
           )

  source = %Object{adapter: :s3, scope: "bucket", key: "cat.jpg", revision: "v1"}

  assert {:ok, resolved} = S3.resolve(source, opts, [])

  assert resolved.internal_cache == :enabled
  assert resolved.cache_semantics.stable? == true
  assert {:strong, seed} = resolved.cache_semantics.byte_identity
  assert seed[:bucket] == "bucket"
  assert seed[:key] == "cat.jpg"
  assert seed[:revision] == "v1"
end

test "s3 without revision isn't stable unless trusted" do
  assert {:ok, opts} =
           S3.validate_options(
             default: [
               region: "us-east-1",
               endpoint: "https://s3.amazonaws.com",
               credentials: {:static, access_key_id: "A", secret_access_key: "S"}
             ]
           )

  source = %Object{adapter: :s3, scope: "bucket", key: "cat.jpg", revision: nil}

  assert {:ok, resolved} = S3.resolve(source, opts, [])

  assert resolved.internal_cache == :disabled
  assert resolved.cache_semantics.byte_identity == :none
end
```

- [ ] **Step 4: Run source adapter tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/source/file_test.exs test/image_pipe/source/http_test.exs test/image_pipe/source/s3_test.exs
```

Expected: fail because adapter options and resolved fields still use `cache`.

- [ ] **Step 5: Add `ImagePipe.Source.CacheSemantics`**

Create `lib/image_pipe/source/cache_semantics.ex`:

```elixir
defmodule ImagePipe.Source.CacheSemantics do
  @moduledoc """
  Source-owned cache facts used by internal and HTTP cache decisions.

  `byte_identity` seeds must be deterministic, non-secret, and stable across
  nodes for the same source bytes. The core validates the tagged shape but does
  not validate seed contents structurally.
  """

  @enforce_keys [:byte_identity, :stable?]
  defstruct @enforce_keys

  @type byte_identity :: {:strong, term()} | :none

  @type t :: %__MODULE__{
          byte_identity: byte_identity(),
          stable?: boolean()
        }
end
```

- [ ] **Step 6: Migrate `Source.Resolved` fields**

Replace `lib/image_pipe/source/resolved.ex` with:

```elixir
defmodule ImagePipe.Source.Resolved do
  @moduledoc false

  alias ImagePipe.Source.CacheSemantics

  @enforce_keys [
    :adapter,
    :source_kind,
    :identity,
    :internal_cache,
    :http_cache,
    :cache_semantics,
    :fetch
  ]
  defstruct @enforce_keys

  @type internal_cache :: :enabled | :disabled
  @type http_cache :: :inherit | :disabled | :enabled

  @type t :: %__MODULE__{
          adapter: atom(),
          source_kind: :path | :url | :object | :reference,
          identity: term(),
          internal_cache: internal_cache(),
          http_cache: http_cache(),
          cache_semantics: CacheSemantics.t(),
          fetch: term()
        }
end
```

- [ ] **Step 7: Update source validation for new fields**

In `lib/image_pipe/source.ex`, add `CacheSemantics` to the Boundary export list:

```elixir
exports: [
  CacheSemantics,
  Resolved,
  Response,
  StreamError,
  HTTP,
  File,
  S3
]
```

Add aliases and policies near the existing aliases/constants:

```elixir
alias ImagePipe.Source.CacheSemantics

@internal_cache_policies [:enabled, :disabled]
@http_cache_policies [:inherit, :enabled, :disabled]
```

Remove `@cache_policies`.

Replace `valid_resolved?/1` with:

```elixir
defp valid_resolved?(%Resolved{} = resolved) do
  resolved.source_kind in @source_kinds and
    resolved.internal_cache in @internal_cache_policies and
    resolved.http_cache in @http_cache_policies and
    valid_cache_semantics?(resolved.cache_semantics) and
    Identity.valid?(resolved.identity)
end

defp valid_cache_semantics?(%CacheSemantics{byte_identity: :none, stable?: stable?}),
  do: is_boolean(stable?)

defp valid_cache_semantics?(%CacheSemantics{byte_identity: {:strong, _seed}, stable?: stable?}),
  do: is_boolean(stable?)

defp valid_cache_semantics?(_cache_semantics), do: false
```

This validates the cache semantics shape at the adapter boundary. It doesn't
try to prove that strong seed material is stable. Adapters own that contract,
and adapter tests should assert the exact seed shape for trusted paths.

- [ ] **Step 8: Update file source defaults**

In `lib/image_pipe/source/file.ex`, add `CacheSemantics` alias:

```elixir
alias ImagePipe.Source.CacheSemantics
```

Replace the options schema `cache:` entry with:

```elixir
stable: [type: {:in, [:auto, :trusted]}, default: :auto],
internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit]
```

Update the resolved struct fields:

```elixir
stable? = Keyword.fetch!(opts, :stable) == :trusted

{:ok,
 %Resolved{
   adapter: :path,
   source_kind: :path,
   identity: [
     kind: :path,
     adapter: :path,
     root: Keyword.fetch!(opts, :root_id),
     path: segments
   ],
   internal_cache: internal_cache_mode(opts, stable?),
   http_cache: Keyword.fetch!(opts, :http_cache),
   cache_semantics: cache_semantics(opts, stable?, [
     kind: :path,
     adapter: :path,
     root: Keyword.fetch!(opts, :root_id),
     path: segments
   ]),
   fetch: [path: path, root: Keyword.fetch!(opts, :root), segments: segments]
 }}
```

Add helpers:

```elixir
defp internal_cache_mode(opts, stable?) do
  case Keyword.fetch!(opts, :internal_cache) do
    :enabled -> :enabled
    :disabled -> :disabled
    :auto -> if stable?, do: :enabled, else: :disabled
  end
end

defp cache_semantics(opts, stable?, identity) do
  byte_identity =
    if Keyword.fetch!(opts, :stable) == :trusted do
      {:strong, identity}
    else
      :none
    end

  %CacheSemantics{byte_identity: byte_identity, stable?: stable?}
end
```

Keep file sources not stable by default; don't add `File.stat/2` byte identity.

- [ ] **Step 9: Update HTTP source defaults and header stripping**

In `lib/image_pipe/source/http.ex`, add `CacheSemantics` alias:

```elixir
alias ImagePipe.Source.CacheSemantics
```

Replace the options schema `cache:` entry with:

```elixir
stable: [type: {:in, [:auto, :trusted]}, default: :auto],
internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit]
```

In `resolve/3`, build identity once:

```elixir
identity = [
  kind: :url,
  adapter: scheme,
  scheme: scheme,
  host: host,
  port: port,
  path: source.path,
  query: source.query
]

stable? = Keyword.fetch!(opts, :stable) == :trusted
internal_cache = internal_cache_mode(opts, stable?)
```

Use these fields in `%Resolved{}`:

```elixir
identity: identity,
internal_cache: internal_cache,
http_cache: Keyword.fetch!(opts, :http_cache),
cache_semantics: cache_semantics(opts, stable?, identity),
fetch: [
  url: build_url(%{source | host: host, port: port}),
  internal_cache: internal_cache
]
```

In `fetch/3`, use `fetch[:internal_cache]`:

```elixir
|> sanitize_req_options(fetch[:internal_cache])
```

Replace `denied_header_names/1` clauses:

```elixir
defp denied_header_names(:enabled), do: @host_header_names ++ @cacheable_byte_header_names
defp denied_header_names(:disabled), do: @host_header_names
```

Add the same `internal_cache_mode/2` helper as in `File`.

Add `cache_semantics/3`:

```elixir
defp cache_semantics(opts, stable?, identity) do
  byte_identity =
    if Keyword.fetch!(opts, :stable) == :trusted do
      {:strong, redacted_http_identity(identity)}
    else
      :none
    end

  %CacheSemantics{byte_identity: byte_identity, stable?: stable?}
end

defp redacted_http_identity(identity) do
  case Keyword.fetch!(identity, :query) do
    nil ->
      Keyword.delete(identity, :query)

    query ->
      identity
      |> Keyword.delete(:query)
      |> Keyword.put(:query_sha256, :crypto.hash(:sha256, query) |> Base.encode16(case: :lower))
  end
end
```

This keeps raw signed query strings out of byte-identity material.

- [ ] **Step 10: Update S3 source defaults**

In `lib/image_pipe/source/s3.ex`, add `CacheSemantics` alias:

```elixir
alias ImagePipe.Source.CacheSemantics
```

Replace the config schema `cache:` entry with:

```elixir
stable: [type: {:in, [:auto, :trusted]}, default: :auto],
internal_cache: [type: {:in, [:auto, :enabled, :disabled]}, default: :auto],
http_cache: [type: {:in, [:inherit, :disabled, :enabled]}, default: :inherit],
```

In `resolve/3`, build identity once:

```elixir
identity = [
  kind: :object,
  adapter: :s3,
  endpoint: endpoint,
  bucket: bucket,
  key: key,
  revision: revision
]

stable? = s3_stable?(config, revision)
internal_cache = internal_cache_mode(config, stable?)
```

Use these fields in `%Resolved{}`:

```elixir
identity: identity,
internal_cache: internal_cache,
http_cache: Keyword.fetch!(config, :http_cache),
cache_semantics: cache_semantics(stable?, identity),
fetch:
  [
    endpoint: endpoint,
    bucket: bucket,
    key: key,
    revision: revision,
    region: Keyword.fetch!(config, :region),
    credentials: Keyword.get(config, :credentials),
    req_options: Keyword.fetch!(config, :req_options),
    internal_cache: internal_cache
  ]
  |> Keyword.merge(Keyword.take(config, @timeout_keys))
```

In `fetch/3`, use:

```elixir
|> sanitize_req_options(fetch[:internal_cache])
```

Replace `denied_header_names/1` clauses:

```elixir
defp denied_header_names(:enabled), do: @signed_header_names ++ @cacheable_byte_header_names
defp denied_header_names(:disabled), do: @signed_header_names
```

Add helpers:

```elixir
defp s3_stable?(config, revision) do
  Keyword.fetch!(config, :stable) == :trusted or is_binary(revision)
end

defp internal_cache_mode(config, stable?) do
  case Keyword.fetch!(config, :internal_cache) do
    :enabled -> :enabled
    :disabled -> :disabled
    :auto -> if stable?, do: :enabled, else: :disabled
  end
end

defp cache_semantics(true, identity),
  do: %CacheSemantics{byte_identity: {:strong, identity}, stable?: true}

defp cache_semantics(false, _identity),
  do: %CacheSemantics{byte_identity: :none, stable?: false}
```

- [ ] **Step 11: Update Runner pattern matches**

In `lib/image_pipe/request/runner.ex`, replace:

```elixir
%Source.Resolved{cache: :skip}
%Source.Resolved{cache: :normal}
```

with:

```elixir
%Source.Resolved{internal_cache: :disabled}
%Source.Resolved{internal_cache: :enabled}
```

Don't change the delivery tuple shape in this task. That comes later.

- [ ] **Step 12: Update tests and fixtures that build `Source.Resolved`**

Search:

```bash
rg "%Source\\.Resolved|SourceResolved|cache: :normal|cache: :skip|fetch\\[:cache\\]" lib test
```

For each hand-built `%Source.Resolved{}`, add:

```elixir
internal_cache: :enabled,
http_cache: :inherit,
cache_semantics: %ImagePipe.Source.CacheSemantics{
  byte_identity: :none,
  stable?: false
}
```

Use `internal_cache: :disabled` where the old fixture used `cache: :skip`.

- [ ] **Step 13: Run source and runner tests**

Run:

```bash
mise exec -- mix test test/image_pipe/source_test.exs test/image_pipe/source/file_test.exs test/image_pipe/source/http_test.exs test/image_pipe/source/s3_test.exs test/image_pipe/request_runner_test.exs
```

Expected: pass.

- [ ] **Step 14: Commit source semantics migration**

Run:

```bash
mise exec -- git add lib/image_pipe/source.ex lib/image_pipe/source/cache_semantics.ex lib/image_pipe/source/resolved.ex lib/image_pipe/source/file.ex lib/image_pipe/source/http.ex lib/image_pipe/source/s3.ex lib/image_pipe/request/runner.ex test/image_pipe/source_test.exs test/image_pipe/source/file_test.exs test/image_pipe/source/http_test.exs test/image_pipe/source/s3_test.exs test/image_pipe/request_runner_test.exs
mise exec -- git commit -m "Add source cache semantics"
```

## Task 2: Request Options and Internal Cache Key Version

**Files:**

- Modify: `lib/image_pipe/request/options.ex`
- Modify: `lib/image_pipe/cache/key.ex`
- Test: `test/image_pipe/request_options_test.exs`
- Test: `test/image_pipe/cache/key_test.exs`
- Test: `test/image_pipe/cache/key_property_test.exs`

- [ ] **Step 1: Write failing option validation tests**

Add to `test/image_pipe/request_options_test.exs`:

```elixir
test "http_cache defaults to disabled" do
  opts = ImagePipe.Request.Options.validate!(parser: ImagePipe.Parser.Imgproxy)

  assert Keyword.fetch!(opts, :http_cache) == [mode: :disabled]
end

test "http_cache accepts enabled mode" do
  opts =
    ImagePipe.Request.Options.validate!(
      parser: ImagePipe.Parser.Imgproxy,
      http_cache: [mode: :enabled]
    )

  assert Keyword.fetch!(opts, :http_cache) == [mode: :enabled]
end

test "http_cache rejects unknown mode" do
  assert_raise ArgumentError, ~r/invalid ImagePipe options/, fn ->
    ImagePipe.Request.Options.validate!(
      parser: ImagePipe.Parser.Imgproxy,
      http_cache: [mode: :public]
    )
  end
end
```

- [ ] **Step 2: Run option tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/request_options_test.exs
```

Expected: fail because `:http_cache` isn't a known option.

- [ ] **Step 3: Implement request option validation**

In `lib/image_pipe/request/options.ex`, add to `@options_schema`:

```elixir
http_cache: [
  type: :keyword_list,
  default: [mode: :disabled],
  keys: [
    mode: [type: {:in, [:disabled, :enabled]}, default: :disabled]
  ]
],
```

Keep `:http_cache` out of `@parser_visible_option_keys` and `@source_runtime_option_keys`.

- [ ] **Step 4: Run option tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request_options_test.exs
```

Expected: pass.

- [ ] **Step 5: Write cache key version tests**

Add to `test/image_pipe/cache/key_test.exs`:

```elixir
test "cache key contains representation version" do
  plan = plan(output: %ImagePipe.Plan.Output{mode: {:explicit, :webp}})
  conn = Plug.Test.conn(:get, "/image")

  assert {:ok, key} = ImagePipe.Cache.Key.build(conn, plan, source_identity())

  assert key.data[:representation] == [version: ImagePipe.Cache.Key.representation_version()]
end
```

If the helpers `plan/1` and `source_identity/0` don't exist in the file, add local versions:

```elixir
defp plan(overrides) do
  struct!(
    %ImagePipe.Plan{
      source: %ImagePipe.Plan.Source.Path{segments: ["cat.jpg"]},
      pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
      output: %ImagePipe.Plan.Output{mode: {:explicit, :jpeg}}
    },
    overrides
  )
end

defp source_identity do
  [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]]
end
```

- [ ] **Step 6: Run cache key test and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/cache/key_test.exs
```

Expected: fail because `representation_version/0` and `key.data[:representation]` don't exist.

- [ ] **Step 7: Add representation version to internal key material**

In `lib/image_pipe/cache/key.ex`, add:

```elixir
@representation_version 1
```

Add public internal function:

```elixir
@doc false
@spec representation_version() :: pos_integer()
def representation_version, do: @representation_version
```

Add to `data` in `build/4`:

```elixir
representation: representation_data(),
```

Add helper:

```elixir
defp representation_data, do: [version: @representation_version]
```

Update existing tests that assert the full `key.data` shape so their expected
keyword list includes `representation: [version: 1]`. Update any hand-built
fixtures that mirror the complete cache key data. Don't increment
`@schema_version` for this greenfield internal key shape change.

- [ ] **Step 8: Run cache key tests**

Run:

```bash
mise exec -- mix test test/image_pipe/cache/key_test.exs test/image_pipe/cache/key_property_test.exs
```

Expected: pass.

- [ ] **Step 9: Commit options and key version**

Run:

```bash
mise exec -- git add lib/image_pipe/request/options.ex lib/image_pipe/cache/key.ex test/image_pipe/request_options_test.exs test/image_pipe/cache/key_test.exs test/image_pipe/cache/key_property_test.exs
mise exec -- git commit -m "Add HTTP cache options"
```

## Task 3: Canonical Representation Material

**Files:**

- Modify: `lib/image_pipe/plan.ex`
- Modify: `lib/image_pipe/output/policy.ex`
- Test: `test/image_pipe/plan_test.exs`
- Test: `test/image_pipe/output_policy_test.exs`

- [ ] **Step 1: Write failing representation material tests**

Add to `test/image_pipe/plan_test.exs`:

```elixir
describe "canonical_representation_material/1" do
  test "explicit output contains output rule and quality material" do
    plan = %ImagePipe.Plan{
      source: %ImagePipe.Plan.Source.Path{segments: ["cat.jpg"]},
      pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
      output: %ImagePipe.Plan.Output{
        mode: {:explicit, :webp},
        quality: {:quality, 82},
        format_qualities: %{webp: {:quality, 80}}
      }
    }

    assert {:ok,
            [
              output: [
                mode: :explicit,
                format: :webp,
                quality: {:quality, 82},
                format_qualities: [webp: {:quality, 80}]
              ]
            ]} = ImagePipe.Plan.canonical_representation_material(plan)
  end

  test "automatic output contains symbolic automatic rule" do
    plan = %ImagePipe.Plan{
      source: %ImagePipe.Plan.Source.Path{segments: ["cat.jpg"]},
      pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
      output: %ImagePipe.Plan.Output{mode: :automatic}
    }

    assert {:ok,
            [
              output: [
                mode: :automatic,
                quality: :default,
                format_qualities: []
              ]
            ]} = ImagePipe.Plan.canonical_representation_material(plan)
  end
end
```

- [ ] **Step 2: Run representation tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/plan_test.exs
```

Expected: fail because `ImagePipe.Plan.canonical_representation_material/1` doesn't exist.

- [ ] **Step 3: Implement plan representation material**

In `lib/image_pipe/plan.ex`, add:

```elixir
@spec canonical_representation_material(t()) :: {:ok, keyword()} | :omit_etag
def canonical_representation_material(%__MODULE__{output: %Output{} = output}) do
  {:ok, [output: output_material(output)]}
end

defp output_material(%Output{
       mode: {:explicit, format},
       quality: quality,
       format_qualities: format_qualities
     }) do
  [
    mode: :explicit,
    format: format,
    quality: quality,
    format_qualities: sorted_format_qualities(format_qualities)
  ]
end

defp output_material(%Output{
       mode: :automatic,
       quality: quality,
       format_qualities: format_qualities
     }) do
  [
    mode: :automatic,
    quality: quality,
    format_qualities: sorted_format_qualities(format_qualities)
  ]
end

defp sorted_format_qualities(format_qualities) when is_map(format_qualities) do
  format_qualities
  |> Map.to_list()
  |> Enum.sort_by(fn {format, _quality} -> format end)
end
```

If current output modes later add `:source` or source-compatible fallback, encode the rule symbolically here. Don't add a per-rule version field; use `@representation_version` in HTTP cache/key material when rule behavior changes.

- [ ] **Step 4: Add output policy material tests**

Add to `test/image_pipe/output_policy_test.exs`:

```elixir
test "automatic output policy exposes Vary Accept and selected candidates from Accept" do
  conn =
    Plug.Test.conn(:get, "/image")
    |> Plug.Conn.put_req_header("accept", "image/webp,image/avif;q=0.1")

  policy =
    ImagePipe.Output.Policy.from_output_plan(
      conn,
      %ImagePipe.Plan.Output{mode: :automatic},
      []
    )

  assert policy.headers == [{"vary", "Accept"}]
  assert policy.modern_candidates != []
end
```

This is a characterization test for the existing boundary. Don't add a new output-policy API unless `HTTPCache` can't derive material from the plan and normalized Accept in Task 4.

- [ ] **Step 5: Run plan/output tests**

Run:

```bash
mise exec -- mix test test/image_pipe/plan_test.exs test/image_pipe/output_policy_test.exs
```

Expected: pass.

- [ ] **Step 6: Commit representation material**

Run:

```bash
mise exec -- git add lib/image_pipe/plan.ex lib/image_pipe/output/policy.ex test/image_pipe/plan_test.exs test/image_pipe/output_policy_test.exs
mise exec -- git commit -m "Add representation cache material"
```

## Task 4: HTTP Cache Preparation Module

**Files:**

- Create: `lib/image_pipe/request/http_cache.ex`
- Create: `lib/image_pipe/response/cache_headers.ex`
- Modify: `lib/image_pipe/request.ex` if Boundary exports need updating
- Modify: `lib/image_pipe/response.ex`
- Test: `test/image_pipe/request/http_cache_test.exs`
- Test: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Write failing preparation tests**

Create `test/image_pipe/request/http_cache_test.exs`:

```elixir
defmodule ImagePipe.Request.HTTPCacheTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Plan.Pipeline
  alias ImagePipe.Plan.Source.Path, as: SourcePath
  alias ImagePipe.Request.HTTPCache
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved

  defp plan(output \\ %Output{mode: {:explicit, :webp}}) do
    %Plan{
      source: %SourcePath{segments: ["cat.jpg"]},
      pipelines: [%Pipeline{operations: []}],
      output: output
    }
  end

  defp resolved(overrides \\ []) do
    struct!(
      %Resolved{
        adapter: :path,
        source_kind: :path,
        identity: [kind: :path, adapter: :path, root: "test", path: ["cat.jpg"]],
        internal_cache: :enabled,
        http_cache: :inherit,
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :path, root: "test", path: ["cat.jpg"]]},
          stable?: true
        },
        fetch: [path: "/tmp/cat.jpg"]
      },
      overrides
    )
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        http_cache: [mode: :enabled],
        telemetry_prefix: [:image_pipe]
      ],
      overrides
    )
  end

  test "enabled mode with strong byte identity emits cache-control and strong etag" do
    prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

    assert %ImagePipe.Response.CacheHeaders{
             representation_headers: [],
             headers: headers,
             etag: etag
           } = prepared

    assert {"cache-control", "public, max-age=31536000, immutable"} in headers
    assert {"etag", etag} in headers
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "disabled mode emits no generated cache headers" do
    prepared =
      HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), http_cache: [mode: :disabled])

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "missing byte identity emits no-store fallback without generated etag" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image"),
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}
        ),
        opts()
      )

    assert prepared.headers == [{"cache-control", "no-store"}]
    assert prepared.etag == nil
  end

  test "host cache-control suppresses generated cache-control and no-store fallback" do
    conn = put_resp_header(conn(:get, "/image"), "cache-control", "public, max-age=60")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(),
        resolved(
          cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}
        ),
        opts()
      )

    assert prepared.headers == []
    assert prepared.etag == nil
  end

  test "host etag suppresses generated etag" do
    conn = put_resp_header(conn(:get, "/image"), "etag", ~s("host"))

    prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

    refute Enum.any?(prepared.headers, fn {name, _value} -> name == "etag" end)
    assert {"cache-control", "public, max-age=31536000, immutable"} in prepared.headers
    assert prepared.etag == nil
  end

  test "automatic output emits representation Vary Accept" do
    prepared =
      HTTPCache.prepare(
        conn(:get, "/image") |> put_req_header("accept", "image/avif,image/webp"),
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept"}]
  end

  test "existing vary merges accept without duplicates" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "Accept-Encoding, Accept")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "Accept-Encoding, Accept"}]
  end

  test "existing vary star suppresses generated public cache headers but keeps representation headers" do
    conn =
      conn(:get, "/image")
      |> put_resp_header("vary", "*")

    prepared =
      HTTPCache.prepare(
        conn,
        plan(%Output{mode: :automatic}),
        resolved(),
        opts()
      )

    assert prepared.representation_headers == [{"vary", "*"}]
    assert prepared.headers == []
    assert prepared.etag == nil
  end

end
```

- [ ] **Step 2: Run preparation tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/request/http_cache_test.exs
```

Expected: fail because `ImagePipe.Request.HTTPCache` doesn't exist.

- [ ] **Step 3: Add the response-owned cache header bundle**

Create `lib/image_pipe/response/cache_headers.ex`:

```elixir
defmodule ImagePipe.Response.CacheHeaders do
  @moduledoc false

  @enforce_keys [:representation_headers, :headers, :etag]
  defstruct @enforce_keys

  @type header :: {String.t(), String.t()}
  @type t :: %__MODULE__{
          representation_headers: [header()],
          headers: [header()],
          etag: String.t() | nil
        }
end
```

Add `CacheHeaders` to the exports list in `lib/image_pipe/response.ex`:

```elixir
exports: [
  CacheHeaders,
  PreparedStream,
  Sender
]
```

This keeps `ImagePipe.Response` independent from `ImagePipe.Request`. `HTTPCache`
builds the value, but Sender only sees a response-owned struct.

- [ ] **Step 4: Implement `HTTPCache.prepare/4`**

Create `lib/image_pipe/request/http_cache.ex`:

```elixir
defmodule ImagePipe.Request.HTTPCache do
  @moduledoc false

  import Plug.Conn, only: [get_req_header: 2, get_resp_header: 2]

  alias ImagePipe.Cache.Key
  alias ImagePipe.Output.Negotiation
  alias ImagePipe.Plan
  alias ImagePipe.Plan.Output
  alias ImagePipe.Response.CacheHeaders
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Telemetry

  @etag_schema 1
  @generated_cache_control "public, max-age=31536000, immutable"
  @no_store "no-store"

  @spec prepare(Plug.Conn.t(), Plan.t(), Resolved.t(), keyword()) :: CacheHeaders.t()
  def prepare(%Plug.Conn{} = conn, %Plan{} = plan, %Resolved{} = resolved, opts) do
    effective_mode = effective_mode(resolved, opts)
    representation_headers = representation_headers(conn, plan)

    {headers, etag, fallback_reason} =
      generated_cache_headers(conn, plan, resolved, opts, effective_mode, representation_headers)

    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:http_cache, :prepare],
      %{},
      %{
        effective_mode: effective_mode,
        byte_identity: byte_identity_kind(resolved.cache_semantics),
        etag: etag_emitted?(etag)
      }
    )

    if fallback_reason do
      Telemetry.execute(
        Telemetry.telemetry_opts(opts),
        [:http_cache, :fallback, :no_store],
        %{},
        %{
          adapter: resolved.adapter,
          source_kind: resolved.source_kind,
          reason: fallback_reason
        }
      )
    end

    %CacheHeaders{
      representation_headers: representation_headers,
      headers: headers,
      etag: etag
    }
  end

  @doc false
  @spec etag_schema() :: pos_integer()
  def etag_schema, do: @etag_schema

  @doc false
  @spec generated_cache_control() :: String.t()
  def generated_cache_control, do: @generated_cache_control

  @doc false
  @spec etag_material(Plug.Conn.t(), Plan.t(), term(), keyword()) :: {:ok, keyword()} | :omit_etag
  def etag_material(conn, %Plan{} = plan, source_seed, opts) do
    with {:ok, _representation_material} <- Plan.canonical_representation_material(plan) do
      {:ok,
       [
         etag_schema: @etag_schema,
         source: source_seed,
         plan: canonical_plan_data(plan, opts),
         accept: accept_material(conn, plan.output, opts),
         representation_version: Key.representation_version()
       ]}
    end
  end

  defp effective_mode(%Resolved{http_cache: :inherit}, opts),
    do: opts |> Keyword.fetch!(:http_cache) |> Keyword.fetch!(:mode)

  defp effective_mode(%Resolved{http_cache: mode}, _opts) when mode in [:enabled, :disabled],
    do: mode

  defp generated_cache_headers(_conn, _plan, _resolved, _opts, :disabled, _representation_headers),
    do: {[], nil, nil}

  defp generated_cache_headers(conn, plan, resolved, opts, :enabled, representation_headers) do
    cond do
      has_resp_header?(conn, "set-cookie") ->
        {[], nil, nil}

      vary_star?(representation_headers) ->
        {[], nil, nil}

      selected_cache_control(conn) == @no_store ->
        {[], nil, nil}

      has_resp_header?(conn, "cache-control") ->
        generated_etag_only(conn, plan, resolved, opts)

      true ->
        generated_cache_control_and_etag(conn, plan, resolved, opts)
    end
  end

  defp generated_cache_control_and_etag(conn, plan, resolved, opts) do
    case generated_etag(conn, plan, resolved, opts) do
      {:etag, etag} ->
        {[{"cache-control", @generated_cache_control}, {"etag", etag}], etag, nil}

      :omit_etag ->
        {[{"cache-control", @no_store}], nil, :missing_representation_material}

      :not_generated ->
        case resolved.cache_semantics do
          %CacheSemantics{byte_identity: :none} ->
            {[{"cache-control", @no_store}], nil, :missing_byte_identity}

          %CacheSemantics{byte_identity: {:strong, _seed}} ->
            if has_resp_header?(conn, "etag"),
              do: {[{"cache-control", @generated_cache_control}], nil, nil},
              else: {[], nil, nil}
        end

    end
  end

  defp generated_etag_only(conn, plan, resolved, opts) do
    case generated_etag(conn, plan, resolved, opts) do
      {:etag, etag} -> {[{"etag", etag}], etag, nil}
      :omit_etag -> {[], nil, nil}
      :not_generated -> {[], nil, nil}
    end
  end

  defp generated_etag(conn, plan, %Resolved{cache_semantics: cache_semantics}, opts) do
    cond do
      has_resp_header?(conn, "etag") ->
        :not_generated

      selected_cache_control(conn) == @no_store ->
        :not_generated

      true ->
        do_generated_etag(conn, plan, cache_semantics, opts)
    end
  end

  defp do_generated_etag(conn, plan, %CacheSemantics{byte_identity: {:strong, seed}}, opts) do
    with {:ok, material} <- etag_material(conn, plan, seed, opts) do
      material
      |> serialize_material()
      |> :crypto.hash(:sha256)
      |> Base.url_encode64(padding: false)
      |> then(&{:etag, ~s("ip#{@etag_schema}-#{&1}")})
    else
      :omit_etag -> :omit_etag
    end
  end

  defp do_generated_etag(_conn, _plan, %CacheSemantics{byte_identity: :none}, _opts),
    do: :not_generated

  defp canonical_plan_data(%Plan{} = plan, opts) do
    {:ok, material} = Key.plan_material(plan, opts)
    Keyword.drop(material, [:cache])
  end

  defp accept_material(conn, %Output{mode: :automatic}, opts) do
    conn
    |> get_req_header("accept")
    |> Enum.join(",")
    |> Negotiation.modern_candidates(opts)
  end

  defp accept_material(_conn, %Output{}, _opts), do: []

  defp representation_headers(conn, %Plan{output: %Output{mode: :automatic}}),
    do: merge_vary(conn, "Accept")

  defp representation_headers(_conn, %Plan{}), do: []

  defp merge_vary(conn, added_name) do
    existing =
      conn
      |> get_resp_header("vary")
      |> Enum.flat_map(&split_vary/1)

    values =
      (existing ++ [added_name])
      |> dedupe_tokens()

    if values == [], do: [], else: [{"vary", Enum.join(values, ", ")}]
  end

  defp split_vary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp dedupe_tokens(tokens) do
    tokens
    |> Enum.reduce([], fn token, acc ->
      if Enum.any?(acc, &(String.downcase(&1) == String.downcase(token))),
        do: acc,
        else: acc ++ [token]
    end)
  end

  defp vary_star?(headers) do
    Enum.any?(headers, fn
      {"vary", value} -> "*" in split_vary(value)
      _header -> false
    end)
  end

  defp selected_cache_control(conn) do
    conn
    |> get_resp_header("cache-control")
    |> Enum.join(",")
    |> String.downcase()
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 == "no-store"))
  end

  defp has_resp_header?(conn, name), do: get_resp_header(conn, name) != []

  defp byte_identity_kind(%CacheSemantics{byte_identity: {:strong, _seed}}), do: :strong
  defp byte_identity_kind(%CacheSemantics{byte_identity: :none}), do: :none

  defp etag_emitted?(nil), do: false
  defp etag_emitted?(_etag), do: true

  defp serialize_material(material) do
    material
    |> canonicalize()
    |> :erlang.term_to_binary([:deterministic])
  end

  defp canonicalize(value) when is_list(value) do
    if Keyword.keyword?(value) do
      value
      |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
      |> Enum.sort_by(fn {key, _item} -> key end)
    else
      Enum.map(value, &canonicalize/1)
    end
  end

  defp canonicalize(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {canonicalize(key), canonicalize(item)} end)
    |> Enum.sort()
  end

  defp canonicalize(value) when is_tuple(value) do
    value
    |> Tuple.to_list()
    |> Enum.map(&canonicalize/1)
    |> List.to_tuple()
  end

  defp canonicalize(value), do: value
end
```

Don't add a catch-all cache semantics fallback here. `Source.Resolved` enforces
`%CacheSemantics{byte_identity: :none | {:strong, term()}}`, so any other shape
is an internal construction bug and should fail during implementation rather
than suppress generated headers.

The goal is to reuse canonical internal key material without including source
identity, selected headers, selected cookies, or cachebuster as ETag-only
inputs.

- [ ] **Step 5: Add production plan material helper**

Add a new `ImagePipe.Cache.Key.plan_material/2` helper that returns canonical
plan/output/transform material without requiring a conn. Don't call
`Plug.Test.conn/2` from production code.

The replacement shape should be:

```elixir
@spec plan_material(Plan.t(), keyword()) :: {:ok, keyword()} | {:error, term()}
def plan_material(%Plan{} = plan, opts) do
  with {:ok, pipelines} <- pipelines_data(plan.pipelines),
       {:ok, output} <- output_data_without_conn(plan.output, opts),
       {:ok, cache} <- cache_data(plan.cachebuster) do
    {:ok,
     [
       pipelines: pipelines,
       transform: transform_data(),
       output: output,
       cache: cache
     ]}
  end
end
```

`cachebuster` stays out of ETag material because it changes URL/cache-key
selection, not encoded bytes. Add a focused test that changing
`plan.cachebuster` changes `ImagePipe.Cache.Key.build/4` data but doesn't
change the generated ETag.

The helper needs a conn-free output material path. Split the current
`output_data/3` shape so `build/4` still records `modern_candidates` from
`Accept`, while `plan_material/2` records only plan/output policy fields:

```elixir
defp output_plan_data(%Output{mode: :automatic} = output, opts) do
  {:ok,
   [
     mode: :automatic,
     auto: [
       avif: Keyword.get(opts, :auto_avif, true),
       webp: Keyword.get(opts, :auto_webp, true)
     ],
     quality: output.quality,
     format_qualities: output.format_qualities
   ]}
end

defp output_plan_data(%Output{mode: {:explicit, format}} = output, _opts) do
  {:ok,
   [
     mode: :explicit,
     format: format,
     quality: output.quality,
     format_qualities: output.format_qualities
   ]}
end

defp output_plan_data(output, _opts), do: {:error, {:invalid_output_plan, output}}

defp output_data(conn, %Output{mode: :automatic} = output, opts) do
  accept_header = conn |> get_req_header("accept") |> Enum.join(",")

  with {:ok, data} <- output_plan_data(output, opts) do
    {:ok, Keyword.put(data, :modern_candidates, Negotiation.modern_candidates(accept_header, opts))}
  end
end

defp output_data(_conn, %Output{} = output, opts), do: output_plan_data(output, opts)
```

Use `output_plan_data/2` from `plan_material/2`. Use
`Plan.canonical_representation_material/1` from `HTTPCache`; don't duplicate an
extra `output:` field in generated ETag material.

No current valid output mode returns `:omit_etag`. Keep the `:omit_etag`
fallback in `HTTPCache` as `Cache-Control: no-store` with reason
`:missing_representation_material`; add a focused test when the first output
mode can hit that branch.

- [ ] **Step 6: Add conditional parsing tests**

Extend `test/image_pipe/request/http_cache_test.exs`:

```elixir
describe "evaluate_conditional/3" do
  test "weak request tag matches generated strong etag for GET" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-abc")}],
      etag: ~s("ip1-abc")
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", ~s(W/"ip1-abc"))

    assert {:not_modified, headers} = HTTPCache.evaluate_conditional(conn, prepared, [])
    assert {"etag", ~s("ip1-abc")} in headers
  end

  test "wildcard form is ignored in v1" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-abc")}],
      etag: ~s("ip1-abc")
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", ~s("ip1-abc", *))

    assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
  end

  test "host etag isn't interpreted when prepared etag is nil" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [],
      etag: nil
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", ~s("host"))

    assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
  end

  test "non-matching if-none-match proceeds" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-abc")}],
      etag: ~s("ip1-abc")
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", ~s("ip1-other"))

    assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
  end

  test "malformed if-none-match proceeds" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-abc")}],
      etag: ~s("ip1-abc")
    }

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", "not-a-quoted-tag")

    assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
  end

  test "non-cacheable methods do not use conditional response handling" do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-abc")}],
      etag: ~s("ip1-abc")
    }

    conn =
      :post
      |> conn("/image")
      |> put_req_header("if-none-match", ~s("ip1-abc"))

    assert :proceed = HTTPCache.evaluate_conditional(conn, prepared, [])
  end
end
```

- [ ] **Step 7: Implement conditional evaluation**

Add to `lib/image_pipe/request/http_cache.ex`:

```elixir
import Plug.Conn, only: [get_req_header: 2, get_resp_header: 2, put_resp_header: 3, send_resp: 3]

@not_modified_header_allowlist ~w(cache-control date etag expires vary)

@spec evaluate_conditional(Plug.Conn.t(), CacheHeaders.t(), keyword()) ::
        :proceed | {:not_modified, [{String.t(), String.t()}]}
def evaluate_conditional(%Plug.Conn{method: "GET"} = conn, %CacheHeaders{etag: etag} = prepared, opts)
    when is_binary(etag) do
  if if_none_match?(conn, etag) do
    headers = not_modified_headers(prepared)

    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:http_cache, :conditional, :match],
      %{},
      %{method: :get}
    )

    {:not_modified, headers}
  else
    :proceed
  end
end

def evaluate_conditional(%Plug.Conn{}, %CacheHeaders{}, _opts), do: :proceed

@spec send_not_modified(Plug.Conn.t(), [{String.t(), String.t()}]) :: Plug.Conn.t()
def send_not_modified(conn, headers) do
  conn =
    Enum.reduce(headers, conn, fn {name, value}, conn ->
      put_resp_header(conn, name, value)
    end)

  send_resp(conn, 304, "")
end

defp if_none_match?(conn, etag) do
  conn
  |> get_req_header("if-none-match")
  |> Enum.join(",")
  |> parse_if_none_match()
  |> tags_match?(etag)
end

defp parse_if_none_match(""), do: []

defp parse_if_none_match(value) do
  tags =
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))

  if "*" in tags, do: :wildcard, else: tags
end

defp tags_match?(:wildcard, _etag), do: false
defp tags_match?(tags, etag), do: Enum.any?(tags, &weak_entity_match?(&1, etag))

defp weak_entity_match?(candidate, etag), do: strip_weak(candidate) == strip_weak(etag)

defp strip_weak("W/" <> rest), do: rest
defp strip_weak(value), do: value

defp not_modified_headers(%CacheHeaders{} = prepared) do
  prepared.headers
  |> Kernel.++(prepared.representation_headers)
  |> Enum.filter(fn {name, _value} -> String.downcase(name) in @not_modified_header_allowlist end)
end
```

Keep wildcard handling simple: if `*` appears anywhere, ignore the conditional request in v1.

- [ ] **Step 8: Run HTTP cache unit tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request/http_cache_test.exs
```

Expected: pass.

- [ ] **Step 9: Run architecture tests**

Run:

```bash
mise exec -- mix test test/image_pipe/architecture_boundary_test.exs
```

Expected: pass. If Boundary reports `ImagePipe.Request.HTTPCache` isn't exported inside the request boundary, update the relevant `use Boundary` declaration with the narrowest export needed.

- [ ] **Step 10: Commit HTTP cache preparation**

Run:

```bash
mise exec -- git add lib/image_pipe/request/http_cache.ex lib/image_pipe/request.ex test/image_pipe/request/http_cache_test.exs test/image_pipe/architecture_boundary_test.exs
mise exec -- git commit -m "Prepare HTTP cache headers"
```

## Task 5: Plug, Runner, and Sender Integration

**Files:**

- Modify: `lib/image_pipe/plug.ex`
- Modify: `lib/image_pipe/request/runner.ex`
- Modify: `lib/image_pipe/response/sender.ex`
- Test: `test/image_pipe/cdn_http_cache_wire_test.exs`
- Test: `test/image_pipe/plug_test.exs`
- Test: `test/image_pipe/request_runner_test.exs`
- Test: `test/image_pipe/response_sender_test.exs`

- [ ] **Step 1: Write failing wire tests for generated headers and 304**

Create `test/image_pipe/cdn_http_cache_wire_test.exs`:

```elixir
defmodule ImagePipe.CDNHTTPCacheWireTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias ImagePipe.Cache.Entry
  alias ImagePipe.Cache.Key
  alias ImagePipe.Parser.Imgproxy.Signature
  alias ImagePipe.Source.CacheSemantics
  alias ImagePipe.Source.Resolved
  alias ImagePipe.Source.Response

  defmodule StableSource do
    @behaviour ImagePipe.Source

    def validate_options(opts), do: {:ok, Keyword.put_new(opts, :telemetry_kind, :stable_test)}

    def resolve(source, _opts, _runtime_opts) do
      path = source.segments

      {:ok,
       %Resolved{
         adapter: :path,
         source_kind: :path,
         identity: [kind: :path, adapter: :path, root: "wire", path: path],
         internal_cache: :enabled,
         http_cache: :enabled,
         cache_semantics: %CacheSemantics{
           byte_identity: {:strong, [kind: :path, root: "wire", path: path]},
           stable?: true
         },
         fetch: [path: path]
       }}
    end

    def fetch(_resolved, opts, _runtime_opts) do
      send(Keyword.fetch!(opts, :test_pid), :source_fetch_called)
      {:ok, %Response{stream: [File.read!("priv/static/images/beach.jpg")]}}
    end
  end

  defmodule CacheProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      :miss
    end

    def open_sink(%Key{}, metadata, opts), do: {:ok, %{metadata: metadata, chunks: [], opts: opts}}
    def write_chunk(state, chunk, _opts), do: {:ok, %{state | chunks: [chunk | state.chunks]}}

    def commit_sink(state, _opts) do
      entry = %Entry{
        body: state.chunks |> Enum.reverse() |> IO.iodata_to_binary(),
        content_type: state.metadata.content_type,
        headers: state.metadata.headers,
        created_at: state.metadata.created_at
      }

      send(Keyword.fetch!(state.opts, :test_pid), {:cache_put, entry})
      :ok
    end

    def abort_sink(_state, _opts), do: :ok
  end

  defmodule CacheHitProbe do
    @behaviour ImagePipe.Cache

    def get(%Key{} = key, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:cache_get, key})
      {:hit, Keyword.fetch!(opts, :entry)}
    end

    def open_sink(_key, _metadata, _opts), do: raise("cache hit should not write")
    def write_chunk(_state, _chunk, _opts), do: raise("cache hit should not write")
    def commit_sink(_state, _opts), do: raise("cache hit should not write")
    def abort_sink(_state, _opts), do: :ok
  end

  setup do
    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheProbe, test_pid: self()},
        test_pid: self(),
        http_cache: [mode: :enabled]
      )

    [opts: opts]
  end

  test "stable public route emits cache-control and etag", %{opts: opts} do
    conn = ImagePipe.Plug.call(conn(:get, signed_path("/plain/beach.jpg")), opts)

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]

    assert [etag] = Plug.Conn.get_resp_header(conn, "etag")
    assert etag =~ ~r/^"ip1-[A-Za-z0-9_-]+"$/
  end

  test "matching if-none-match returns before cache lookup and source fetch", %{opts: opts} do
    first = ImagePipe.Plug.call(conn(:get, signed_path("/plain/beach.jpg")), opts)
    [etag] = Plug.Conn.get_resp_header(first, "etag")

    assert_received :source_fetch_called
    flush_messages()

    conn =
      :get
      |> conn(signed_path("/plain/beach.jpg"))
      |> put_req_header("if-none-match", etag)
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 304
    assert conn.resp_body == ""
    assert Plug.Conn.get_resp_header(conn, "etag") == [etag]
    assert Plug.Conn.get_resp_header(conn, "content-type") == []
    refute_received {:cache_get, %Key{}}
    refute_received :source_fetch_called
  end

  test "existing vary is merged in the final response", %{opts: opts} do
    conn =
      :get
      |> conn(signed_path("/plain/beach.jpg"))
      |> put_req_header("accept", "image/avif,image/webp")
      |> put_resp_header("vary", "Accept-Encoding")
      |> ImagePipe.Plug.call(opts)

    assert conn.status == 200
    assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept-Encoding, Accept"]
  end

  test "request cookie does not change generated headers or source fetch", %{opts: opts} do
    without_cookie = ImagePipe.Plug.call(conn(:get, signed_path("/plain/beach.jpg")), opts)
    [etag] = Plug.Conn.get_resp_header(without_cookie, "etag")

    flush_messages()

    with_cookie =
      :get
      |> conn(signed_path("/plain/beach.jpg"))
      |> put_req_header("cookie", "session=private")
      |> ImagePipe.Plug.call(opts)

    assert Plug.Conn.get_resp_header(with_cookie, "etag") == [etag]
    assert Plug.Conn.get_resp_header(with_cookie, "vary") != ["Cookie"]
    assert_received :source_fetch_called
  end

  test "internal cache hit returns 200 with current prepared etag" do
    entry = %Entry{
      body: "cached body",
      content_type: "image/jpeg",
      headers: [{"cache-control", "public, max-age=60"}],
      created_at: DateTime.utc_now()
    }

    opts =
      ImagePipe.Plug.init(
        parser: ImagePipe.Parser.Imgproxy,
        sources: [path: {StableSource, test_pid: self()}],
        cache: {CacheHitProbe, test_pid: self(), entry: entry},
        http_cache: [mode: :enabled]
      )

    conn = ImagePipe.Plug.call(conn(:get, signed_path("/plain/beach.jpg")), opts)

    assert conn.status == 200
    assert conn.resp_body == "cached body"
    assert [etag] = Plug.Conn.get_resp_header(conn, "etag")
    assert String.starts_with?(etag, "\"ip1-")
    assert Plug.Conn.get_resp_header(conn, "cache-control") == [
             "public, max-age=31536000, immutable"
           ]
    refute_received :source_fetch_called
  end

  test "transform option order variants produce the same etag", %{opts: opts} do
    left =
      ImagePipe.Plug.call(
        conn(:get, signed_path("/rs:fill:0:400:0/c:0.5:0.5/plain/beach.jpg")),
        opts
      )

    right =
      ImagePipe.Plug.call(
        conn(:get, signed_path("/c:0.5:0.5/rs:fill:0:400:0/plain/beach.jpg")),
        opts
      )

    assert Plug.Conn.get_resp_header(left, "etag") == Plug.Conn.get_resp_header(right, "etag")
  end

  defp signed_path(path) do
    salt = "secret"
    signature = Signature.sign_path(path, salt: salt)
    "/" <> signature <> path
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end
end
```

Adjust signing helper to match current parser test conventions if `Signature.sign_path/2` differs.

- [ ] **Step 2: Run wire tests and verify failure**

Run:

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs
```

Expected: fail because Plug doesn't prepare HTTP cache headers or return `304`.

- [ ] **Step 3: Prepare HTTP cache in the Plug**

In `lib/image_pipe/plug.ex`, add alias:

```elixir
alias ImagePipe.Request.HTTPCache
```

Inside the success branch of `do_call/2`, replace:

```elixir
result = Runner.run(conn, plan, resolved_source, opts)
```

with:

```elixir
prepared_http_cache = HTTPCache.prepare(conn, plan, resolved_source, opts)

case HTTPCache.evaluate_conditional(conn, prepared_http_cache, opts) do
  {:not_modified, headers} ->
    result = :not_modified

    {conn, send_metadata} =
      send_response(conn, opts, result, fn ->
        HTTPCache.send_not_modified(conn, headers)
      end)

    {conn, request_stop_metadata(result, send_metadata)}

  :proceed ->
    result = Runner.run(conn, plan, resolved_source, prepared_http_cache, opts)

    {conn, send_metadata} =
      send_response(conn, opts, request_result(result), fn ->
        Sender.send_result(conn, result, opts)
      end)

    {conn, request_stop_metadata(result, send_metadata)}
end
```

Add `request_result_metadata(:not_modified)`, returning
`%{result: :not_modified}`, next to the existing request metadata clauses. The
304 branch should use the same `request_stop_metadata/2` path as success and
error deliveries so future request telemetry changes apply to conditional
responses too.

Keep the parser/plan/source error branches unchanged.

- [ ] **Step 4: Write failing Runner delivery tests**

Add to `test/image_pipe/request_runner_test.exs`:

```elixir
test "cache hit delivery carries prepared HTTP cache value" do
  prepared_http_cache = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"cache-control", "public, max-age=31536000, immutable"}],
    etag: nil
  }

  entry = %Entry{
    body: "cached",
    content_type: "image/jpeg",
    headers: [],
    created_at: DateTime.utc_now()
  }

  resolved_source =
    source_resolved(
      internal_cache: :enabled,
      cache_semantics: %ImagePipe.Source.CacheSemantics{byte_identity: :none, stable?: false}
    )

  assert {:ok, {:cache_entry, ^entry, %Response{}, ^prepared_http_cache}} =
           Runner.run(
             conn(:get, "/image"),
             plan(),
             resolved_source,
             prepared_http_cache,
             cache: {CacheHit, entry: entry}
           )
end
```

If helper names differ, use the existing helper functions in `request_runner_test.exs` and update only the expected tuple shape.

- [ ] **Step 5: Update Runner API and delivery tuples**

In `lib/image_pipe/request/runner.ex`, add alias:

```elixir
alias ImagePipe.Response.CacheHeaders
```

Update type:

```elixir
@type delivery() ::
        {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t()}
        | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
```

Update spec and function head:

```elixir
@spec run(
        Plug.Conn.t(),
        Plan.t(),
        Source.Resolved.t(),
        CacheHeaders.t(),
        keyword()
      ) ::
        {:ok, delivery()} | {:error, error()}
def run(conn, %Plan{} = plan, %Source.Resolved{} = resolved_source, %CacheHeaders{} = prepared_http_cache, opts) do
  run_with_cache_config(conn, plan, resolved_source, prepared_http_cache, opts)
end
```

Thread `prepared_http_cache` through private functions. The cache-hit branch
must return the prepared value:

```elixir
defp run_with_cache_config(conn, plan, %Source.Resolved{internal_cache: :disabled} = resolved_source, prepared_http_cache, opts),
  do: process_prepared_stream(conn, plan, resolved_source, nil, prepared_http_cache, opts)

{:hit, %Key{}, %Entry{} = entry} ->
  {:ok, {:cache_entry, entry, plan.response, prepared_http_cache}}
```

Update cache miss and prepared stream returns:

```elixir
process_prepared_stream(conn, plan, resolved_source, key, prepared_http_cache, opts)
```

and:

```elixir
{:ok, {:prepared_stream, prepared_stream, response, prepared_http_cache}}
```

- [ ] **Step 6: Write failing Sender merge tests**

Add to `test/image_pipe/response_sender_test.exs`:

```elixir
test "cache hits merge generated headers before cached entry headers" do
  entry = %Entry{
    body: "body",
    content_type: "image/webp",
    headers: [{"cache-control", "public, max-age=60"}, {"vary", "Accept"}],
    created_at: DateTime.utc_now()
  }

  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [{"vary", "Accept"}],
    headers: [{"cache-control", "public, max-age=31536000, immutable"}, {"etag", ~s("ip1-test")}],
    etag: ~s("ip1-test")
  }

  conn =
    Sender.send_result(
      conn(:get, "/image"),
      {:ok, {:cache_entry, entry, %Response{}, prepared}},
      []
    )

  assert Plug.Conn.get_resp_header(conn, "cache-control") == [
           "public, max-age=31536000, immutable"
         ]

  assert Plug.Conn.get_resp_header(conn, "etag") == [~s("ip1-test")]
  assert Plug.Conn.get_resp_header(conn, "vary") == ["Accept"]
  assert conn.status == 200
end

test "current host cache-control wins over generated and cached headers" do
  entry = %Entry{
    body: "body",
    content_type: "image/webp",
    headers: [{"cache-control", "public, max-age=60"}],
    created_at: DateTime.utc_now()
  }

  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"cache-control", "public, max-age=31536000, immutable"}],
    etag: nil
  }

  conn =
    :get
    |> conn("/image")
    |> Plug.Conn.put_resp_header("cache-control", "private, max-age=30")
    |> Sender.send_result({:ok, {:cache_entry, entry, %Response{}, prepared}}, [])

  assert Plug.Conn.get_resp_header(conn, "cache-control") == ["private, max-age=30"]
end

test "prepared streams merge generated headers before stream headers" do
  prepared_stream =
    prepared_stream(headers: [{"cache-control", "public, max-age=60"}])

  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"cache-control", "public, max-age=31536000, immutable"}],
    etag: nil
  }

  conn =
    Sender.send_result(
      conn(:get, "/image"),
      {:ok, {:prepared_stream, prepared_stream, %Response{}, prepared}},
      []
    )

  assert Plug.Conn.get_resp_header(conn, "cache-control") == [
           "public, max-age=31536000, immutable"
         ]
end
```

- [ ] **Step 7: Update Sender delivery types and merge logic**

In `lib/image_pipe/response/sender.ex`, add alias:

```elixir
alias ImagePipe.Response.CacheHeaders
```

Update delivery type:

```elixir
@type delivery() ::
        {:cache_entry, Entry.t(), Response.t(), CacheHeaders.t()}
        | {:prepared_stream, PreparedStream.t(), Response.t(), CacheHeaders.t()}
```

Update `send_result/3` clauses:

```elixir
def send_result(
      %Plug.Conn{} = conn,
      {:ok, {:cache_entry, %Entry{} = entry, %Response{} = response, %CacheHeaders{} = prepared_http_cache}},
      opts
    ) do
  send_cache_entry(conn, entry, response, prepared_http_cache, opts)
end

def send_result(
      %Plug.Conn{} = conn,
      {:ok,
       {:prepared_stream, %PreparedStream{} = prepared_stream, %Response{} = response,
        %CacheHeaders{} = prepared_http_cache}},
      opts
    ) do
  send_prepared_stream(conn, prepared_stream, response, prepared_http_cache, opts)
end
```

Add merge helpers:

```elixir
defp merge_delivery_headers(conn, cached_or_stream_headers, %CacheHeaders{} = prepared) do
  []
  |> merge_header_list(prepared.headers)
  |> merge_authoritative_header_list(prepared.representation_headers)
  |> merge_header_list(cached_or_stream_headers)
  |> reject_existing_conn_headers(conn, authoritative_header_names(prepared.representation_headers))
end

defp merge_header_list(base, additions) do
  Enum.reduce(additions, base, fn {name, value}, headers ->
    put_header_unless_present(headers, name, value)
  end)
end

defp put_header_unless_present(headers, name, value) do
  downcased = String.downcase(name)

  if Enum.any?(headers, fn {existing_name, _existing_value} ->
       String.downcase(existing_name) == downcased
     end) do
    headers
  else
    headers ++ [{downcased, value}]
  end
end

defp merge_authoritative_header_list(base, additions) do
  Enum.reduce(additions, base, fn {name, value}, headers ->
    put_header_replacing_existing(headers, name, value)
  end)
end

defp put_header_replacing_existing(headers, name, value) do
  downcased = String.downcase(name)

  headers
  |> Enum.reject(fn {existing_name, _existing_value} -> String.downcase(existing_name) == downcased end)
  |> Kernel.++([{downcased, value}])
end

defp authoritative_header_names(headers),
  do: Enum.map(headers, fn {name, _value} -> String.downcase(name) end)

defp reject_existing_conn_headers(headers, conn, authoritative_names) do
  Enum.reject(headers, fn {name, _value} ->
    name = String.downcase(name)
    name not in authoritative_names and Plug.Conn.get_resp_header(conn, name) != []
  end)
end
```

`representation_headers` are authoritative because `HTTPCache.prepare/4`
already merged the current conn value. This is required for `Vary`; otherwise a
preexisting `Vary: Accept-Encoding` on the conn would cause Sender to discard
the prepared `Vary: Accept-Encoding, Accept`.

Use this in cache-hit path:

```elixir
defp send_cache_entry(%Plug.Conn{} = conn, %Entry{} = entry, %Response{} = response, %CacheHeaders{} = prepared_http_cache, opts) do
  with {:ok, headers} <- Entry.cacheable_headers(entry.headers),
       headers <- merge_delivery_headers(conn, headers, prepared_http_cache),
       {:ok, headers} <- delivery_headers(headers, response, entry.content_type) do
    Telemetry.execute(
      Telemetry.telemetry_opts(opts),
      [:http_cache, :cache_hit, :headers],
      %{},
      %{etag: not is_nil(prepared_http_cache.etag)}
    )

    send_normalized_cache_entry(conn, entry, headers)
  else
    {:error, error} -> send_cache_error(conn, error)
  end
end
```

Use this in prepared stream path before `put_resp_headers/2`:

```elixir
headers = merge_delivery_headers(conn, prepared_stream.headers, prepared_http_cache)
prepared_stream = %{prepared_stream | headers: headers}
```

Don't store generated `etag` in cache entries.

- [ ] **Step 8: Run Runner/Sender focused tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request_runner_test.exs test/image_pipe/response_sender_test.exs
```

Expected: pass.

- [ ] **Step 9: Run Plug wire tests**

Run:

```bash
mise exec -- mix test test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/plug_test.exs
```

Expected: pass.

- [ ] **Step 10: Commit Plug, Runner, and Sender integration**

Run:

```bash
mise exec -- git add lib/image_pipe/plug.ex lib/image_pipe/request/runner.ex lib/image_pipe/response/sender.ex test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/plug_test.exs test/image_pipe/request_runner_test.exs test/image_pipe/response_sender_test.exs
mise exec -- git commit -m "Integrate HTTP cache delivery"
```

## Task 6: HTTP Cache Edge Cases and Properties

**Files:**

- Modify: `test/image_pipe/request/http_cache_test.exs`
- Modify: `test/image_pipe/cdn_http_cache_wire_test.exs`

- [ ] **Step 1: Add focused edge-case tests**

Add to `test/image_pipe/request/http_cache_test.exs`:

```elixir
test "set-cookie suppresses generated public cache headers" do
  conn = put_resp_header(conn(:get, "/image"), "set-cookie", "a=b")

  prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

  assert prepared.headers == []
  assert prepared.etag == nil
end

test "cache-control no-store suppresses generated etag" do
  conn = put_resp_header(conn(:get, "/image"), "cache-control", "no-store")

  prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

  assert prepared.headers == []
  assert prepared.etag == nil
end

test "explicit output doesn't emit Vary Accept" do
  prepared = HTTPCache.prepare(conn(:get, "/image"), plan(%Output{mode: {:explicit, :jpeg}}), resolved(), opts())

  assert prepared.representation_headers == []
end

test "client hints don't enter generated vary" do
  conn =
    conn(:get, "/image")
    |> put_req_header("width", "600")
    |> put_req_header("dpr", "2")
    |> put_req_header("sec-ch-width", "600")

  prepared = HTTPCache.prepare(conn, plan(), resolved(), opts())

  refute Enum.any?(prepared.representation_headers, fn {_name, value} ->
           String.contains?(String.downcase(value), "width")
         end)
end

test "plan expires does not change generated cache-control" do
  base = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  expiring =
    HTTPCache.prepare(
      conn(:get, "/image"),
      %{plan() | expires: 1_899_345_600},
      resolved(),
      opts()
    )

  assert header(base.headers, "cache-control") == header(expiring.headers, "cache-control")
end

test "cachebuster changes internal key data but not generated etag" do
  base_plan = plan()
  busted_plan = %{plan() | cachebuster: "v2"}
  plug_conn = conn(:get, "/image")

  assert {:ok, base_key} = ImagePipe.Cache.Key.build(plug_conn, base_plan, resolved().identity)
  assert {:ok, busted_key} = ImagePipe.Cache.Key.build(plug_conn, busted_plan, resolved().identity)
  assert base_key.data[:cache] != busted_key.data[:cache]

  base = HTTPCache.prepare(conn(:get, "/image"), base_plan, resolved(), opts())
  busted = HTTPCache.prepare(conn(:get, "/image"), busted_plan, resolved(), opts())

  assert base.etag == busted.etag
end

test "source revision changes generated etag" do
  left =
    HTTPCache.prepare(
      conn(:get, "/image"),
      plan(),
      resolved(
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :object, adapter: :s3, bucket: "b", key: "cat.jpg", revision: "v1"]},
          stable?: true
        }
      ),
      opts()
    )

  right =
    HTTPCache.prepare(
      conn(:get, "/image"),
      plan(),
      resolved(
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :object, adapter: :s3, bucket: "b", key: "cat.jpg", revision: "v2"]},
          stable?: true
        }
      ),
      opts()
    )

  assert left.etag != right.etag
end

test "visible etag prefix comes from etag schema" do
  prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  assert String.starts_with?(prepared.etag, ~s("ip#{HTTPCache.etag_schema()}-))
end

test "etag material uses the internal cache representation version" do
  assert {:strong, seed} = resolved().cache_semantics.byte_identity

  assert {:ok, material} = HTTPCache.etag_material(conn(:get, "/image"), plan(), seed, opts())
  assert material[:representation_version] == ImagePipe.Cache.Key.representation_version()
end

test "cookie request header does not enter generated vary or etag" do
  without_cookie = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  with_cookie =
    :get
    |> conn("/image")
    |> put_req_header("cookie", "session=private")
    |> HTTPCache.prepare(plan(), resolved(), opts())

  assert with_cookie.etag == without_cookie.etag
  refute Enum.any?(with_cookie.representation_headers, fn {_name, value} ->
           String.downcase(value) == "cookie"
         end)
end

defp header(headers, name) do
  headers
  |> Enum.find(fn {header_name, _value} -> header_name == name end)
  |> elem(1)
end
```

- [ ] **Step 2: Add property tests for ETag determinism**

If `test/image_pipe/request/http_cache_test.exs` doesn't use StreamData yet, create a property section with:

```elixir
use ExUnitProperties

property "whitespace around if-none-match tags doesn't change matching" do
  check all left <- member_of(["", " ", "  ", "\t"]),
            right <- member_of(["", " ", "  ", "\t"]) do
    prepared = %ImagePipe.Response.CacheHeaders{
      representation_headers: [],
      headers: [{"etag", ~s("ip1-token")}],
      etag: ~s("ip1-token")
    }

    header = left <> ~s(W/"ip1-token") <> right

    conn =
      :get
      |> conn("/image")
      |> put_req_header("if-none-match", header)

    assert {:not_modified, _headers} = HTTPCache.evaluate_conditional(conn, prepared, [])
  end
end
```

Add comma-separated and generated ETag material properties:

```elixir
test "comma-separated weak and strong tags can match generated etag" do
  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"etag", ~s("ip1-token")}],
    etag: ~s("ip1-token")
  }

  conn =
    :get
    |> conn("/image")
    |> put_req_header("if-none-match", ~s("other", W/"ip1-token"))

  assert {:not_modified, _headers} = HTTPCache.evaluate_conditional(conn, prepared, [])
end

test "equivalent Accept capability material produces the same generated etag" do
  left =
    :get
    |> conn("/image")
    |> put_req_header("accept", "image/avif,image/webp")
    |> HTTPCache.prepare(plan(%Output{mode: :automatic}), resolved(), opts())

  right =
    :get
    |> conn("/image")
    |> put_req_header("accept", "image/avif;q=1.0,image/webp;q=0.8")
    |> HTTPCache.prepare(plan(%Output{mode: :automatic}), resolved(), opts())

  assert left.etag == right.etag
end

test "different source byte identities produce different generated etags" do
  left = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  right =
    HTTPCache.prepare(
      conn(:get, "/image"),
      plan(),
      resolved(
        cache_semantics: %CacheSemantics{
          byte_identity: {:strong, [kind: :path, root: "test", path: ["other.jpg"]]},
          stable?: true
        }
      ),
      opts()
    )

  assert left.etag != right.etag
end

test "etag serialization is deterministic for the same prepared inputs" do
  first = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())
  second = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  assert first.etag == second.etag
end
```

- [ ] **Step 3: Add symbolic rule material tests**

Add to `test/image_pipe/plan_test.exs` when source-compatible output exists. If it doesn't exist yet, add a comment-free test for the existing source-preserving automatic rule:

```elixir
test "automatic output material contains the symbolic rule instead of a resolved branch" do
  plan = %ImagePipe.Plan{
    source: %ImagePipe.Plan.Source.Path{segments: ["alpha.png"]},
    pipelines: [%ImagePipe.Plan.Pipeline{operations: []}],
    output: %ImagePipe.Plan.Output{mode: :automatic}
  }

  assert {:ok, [output: output]} = ImagePipe.Plan.canonical_representation_material(plan)
  assert output[:mode] == :automatic
  refute Keyword.has_key?(output, :resolved_format)
end
```

- [ ] **Step 4: Run edge/property tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request/http_cache_test.exs test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/plan_test.exs
```

Expected: pass.

- [ ] **Step 5: Commit HTTP cache edge tests**

Run:

```bash
mise exec -- git add test/image_pipe/request/http_cache_test.exs test/image_pipe/cdn_http_cache_wire_test.exs test/image_pipe/plan_test.exs
mise exec -- git commit -m "Cover HTTP cache edge cases"
```

## Task 7: Telemetry Coverage

**Files:**

- Modify: `test/image_pipe/telemetry_test.exs`
- Modify: `test/image_pipe/request/http_cache_test.exs`
- Modify: `lib/image_pipe/request/http_cache.ex`
- Modify: `lib/image_pipe/response/sender.ex`

- [ ] **Step 1: Add telemetry metadata tests**

Add to `test/image_pipe/request/http_cache_test.exs`:

```elixir
test "prepare telemetry is low-cardinality" do
  attach_telemetry([[:image_pipe, :http_cache, :prepare]])

  _prepared = HTTPCache.prepare(conn(:get, "/image"), plan(), resolved(), opts())

  assert_receive {:telemetry_event, [:image_pipe, :http_cache, :prepare], %{},
                  %{effective_mode: :enabled, byte_identity: :strong, etag: true} = metadata}

  refute Map.has_key?(metadata, :path)
  refute Map.has_key?(metadata, :etag_value)
  refute Map.has_key?(metadata, :source_identity)
end

test "no-store fallback telemetry is required and low-cardinality" do
  attach_telemetry([[:image_pipe, :http_cache, :fallback, :no_store]])

  _prepared =
    HTTPCache.prepare(
      conn(:get, "/image"),
      plan(),
      resolved(cache_semantics: %CacheSemantics{byte_identity: :none, stable?: false}),
      opts()
    )

  assert_receive {:telemetry_event, [:image_pipe, :http_cache, :fallback, :no_store], %{},
                  %{adapter: :path, source_kind: :path, reason: :missing_byte_identity} = metadata}

  refute Map.has_key?(metadata, :path)
  refute Map.has_key?(metadata, :url)
  refute Map.has_key?(metadata, :etag)
end
```

If no `attach_telemetry/1` helper exists in this test module, copy the helper from existing telemetry tests:

```elixir
defp attach_telemetry(events) do
  test_pid = self()
  handler_id = {__MODULE__, make_ref()}

  :ok =
    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(test_pid, {:telemetry_event, event, measurements, metadata})
      end,
      nil
    )

  on_exit(fn -> :telemetry.detach(handler_id) end)
end
```

- [ ] **Step 2: Add conditional and cache-hit telemetry tests**

Add to `test/image_pipe/request/http_cache_test.exs`:

```elixir
test "conditional match telemetry omits etag and path" do
  attach_telemetry([[:image_pipe, :http_cache, :conditional, :match]])

  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"etag", ~s("ip1-token")}],
    etag: ~s("ip1-token")
  }

  conn =
    :get
    |> conn("/image")
    |> put_req_header("if-none-match", ~s("ip1-token"))

  assert {:not_modified, _headers} = HTTPCache.evaluate_conditional(conn, prepared, opts())

  assert_receive {:telemetry_event, [:image_pipe, :http_cache, :conditional, :match], %{},
                  %{method: :get} = metadata}

  refute Map.has_key?(metadata, :etag)
  refute Map.has_key?(metadata, :path)
end
```

Add cache-hit telemetry coverage to `test/image_pipe/response_sender_test.exs`:

```elixir
test "cache hit header telemetry is low-cardinality" do
  attach_telemetry([[:image_pipe, :http_cache, :cache_hit, :headers]])

  entry = %Entry{
    body: "body",
    content_type: "image/webp",
    headers: [],
    created_at: DateTime.utc_now()
  }

  prepared = %ImagePipe.Response.CacheHeaders{
    representation_headers: [],
    headers: [{"etag", ~s("ip1-token")}],
    etag: ~s("ip1-token")
  }

  _conn =
    Sender.send_result(
      conn(:get, "/image"),
      {:ok, {:cache_entry, entry, %Response{}, prepared}},
      []
    )

  assert_receive {:telemetry_event, [:image_pipe, :http_cache, :cache_hit, :headers], %{},
                  %{etag: true} = metadata}

  refute Map.has_key?(metadata, :path)
  refute Map.has_key?(metadata, :etag_value)
end
```

- [ ] **Step 3: Run telemetry tests**

Run:

```bash
mise exec -- mix test test/image_pipe/request/http_cache_test.exs test/image_pipe/response_sender_test.exs test/image_pipe/telemetry_test.exs
```

Expected: pass.

- [ ] **Step 4: Commit telemetry coverage**

Run:

```bash
mise exec -- git add lib/image_pipe/request/http_cache.ex lib/image_pipe/response/sender.ex test/image_pipe/request/http_cache_test.exs test/image_pipe/response_sender_test.exs test/image_pipe/telemetry_test.exs
mise exec -- git commit -m "Add HTTP cache telemetry"
```

## Task 8: User Documentation

**Files:**

- Modify: `README.md` or create `docs/cdn-http-cache.md`
- Modify: `README.md` if a new doc is created and needs linking

- [ ] **Step 1: Draft user-facing CDN cache docs**

If the README is already long, create `docs/cdn-http-cache.md` with:

```markdown
# CDN HTTP Caching

ImagePipe can emit HTTP cache headers for public image routes when the source
identity names stable bytes. This is opt-in.

```elixir
plug ImagePipe.Plug,
  parser: MyApp.ImageParser,
  sources: [
    s3:
      {ImagePipe.Source.S3,
       default: [
         endpoint: "https://s3.example.test",
         region: "us-east-1",
         credentials: credentials,
         http_cache: :enabled,
         stable: :trusted
       ]}
  ],
  http_cache: [mode: :enabled]
```

`http_cache: :enabled` allows generated shared-cache headers. `stable:
:trusted` tells the source adapter that the resolved source identity names bytes
that don't change under that identity.

For S3 objects with a revision, ImagePipe can infer stability because the
resolved fetch includes `versionId`.

Generated successful responses can include:

```http
Cache-Control: public, max-age=31536000, immutable
ETag: "ip1-..."
Vary: Accept
```

`Vary: Accept` appears only when automatic output format selection uses the
request `Accept` header. Configure the CDN cache key to include `Accept` for
automatic output routes.

If a route enables HTTP caching but the resolved source doesn't provide byte
identity, ImagePipe emits:

```http
Cache-Control: no-store
```

and doesn't emit a generated ETag. The telemetry event
`[:image_pipe, :http_cache, :fallback, :no_store]` marks this configuration.

ImagePipe doesn't generate public cache headers for responses with `Set-Cookie`
or `Vary: *`, and it doesn't interpret host-supplied ETags for conditional
requests. Routes that need custom validators should leave ImagePipe generated
HTTP caching off and set their own headers.

`Plan.expires` is a parser-level validity field. It doesn't change generated
`Cache-Control`.

Changing the ETag schema prefix, for example from `ip1-` to `ip2-`, invalidates
validators previously stored by browsers and CDNs. Treat that as a deploy-time
cache invalidation.

Changing `representation_version` changes generated ETag hashes without changing
the visible `ip1-` prefix. It also changes internal cache keys, so ImagePipe
doesn't serve an old encoded body with a validator derived from new encoder or
output-policy behavior.
```

Don't mention external projects.

- [ ] **Step 3: Commit documentation**

Run:

```bash
mise exec -- git add README.md docs/cdn-http-cache.md
mise exec -- git commit -m "Document CDN HTTP caching"
```

If `docs/cdn-http-cache.md` wasn't created, omit it from `git add`.

## Task 9: Full Verification

**Files:**

- Verify all changed source, tests, and docs.

- [ ] **Step 1: Format**

Run:

```bash
mise exec -- mix format
```

Expected: no errors.

- [ ] **Step 2: Compile with warnings as errors**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix compile --warnings-as-errors
```

Expected: compile succeeds with no warnings.

- [ ] **Step 3: Run full test suite**

Run:

```bash
VIX_COMPILATION_MODE=PRECOMPILED_LIBVIPS mise exec -- mix test
```

Expected: all tests pass.

- [ ] **Step 5: Check git diff**

Run:

```bash
mise exec -- git status --short
mise exec -- git diff --stat
```

Expected: only intentional files are modified.

- [ ] **Step 6: Final commit if formatting or docs changed**

Run:

```bash
mise exec -- git add .
mise exec -- git commit -m "Verify CDN HTTP cache implementation"
```

Only commit if Step 1 or later verification changed files.

## Self-Review

- Spec coverage: tasks cover source semantics, source adapter options, `Source.Resolved.cache` migration, request options, canonical representation material, ETag material, pre-fetch conditional `304`, `Vary: Accept`, Runner/Sender delivery, internal cache key representation version, telemetry, docs, and full verification.
- Deferred behaviors remain out of scope: no mutable probing, no `Last-Modified`, no arbitrary `Vary`, no Client Hints, no non-pre-fetch ETags, no HEAD-specific behavior, no source-provided cache-control.
- Placeholder scan: no task uses placeholder markers. Steps that depend on existing helper names include exact fallback code or a command to locate/update call sites.
- Type consistency: `CacheSemantics.byte_identity`, `Source.Resolved.internal_cache`, `Source.Resolved.http_cache`, and `ImagePipe.Response.CacheHeaders` fields match across tasks.
