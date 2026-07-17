# TwicPics dialect inversion — oracle prerequisite and phase 1 implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use
> `superpowers:subagent-driven-development` (recommended for the independent
> copy, core-helper, harness, and contract batches) or
> `superpowers:executing-plans` to execute this plan task by task. The exact
> commit subjects are the authoritative resumption ledger; the checked-in plan
> keeps its checkboxes unchanged so execution does not churn the design commit.

**Goal:** Establish a reviewed TwicPics SaaS oracle baseline, then build
`ImagePipe.Dialect.TwicPics` as a self-contained inverted Plug beside the
frozen `ImagePipe.Parser.TwicPics` stack, with exact local cross-arm evidence
and both arms checked independently against the committed SaaS fixtures.

**Architecture:** The new dialect owns a flat config, ordered semantic request,
pipeline-local focus carry, representation identity, cache/delivery lifecycle,
and protocol errors. It reuses product-neutral core boundaries and neutral Plan
operation structs, but never constructs `%ImagePipe.Plan{}` and never depends
on `ImagePipe.Parser`, `ImagePipe.Request`, `ImagePipe.Resolver`, or
`ImagePipe.Renderer`. Phase 1 leaves the framework arm serving users; later
plans close upstream gaps and perform the one-way retirement.

**Tech Stack:** Elixir, Plug, NimbleOptions, Boundary, ExUnit/StreamData,
libvips through Vix/Image, Req-backed TwicPics fixture tooling, Vale, ExDNA.

**Spec:**
`docs/superpowers/specs/2026-07-17-twicpics-dialect-inversion-design.md`.
Phase 2 wave 1 (gap closure) and wave 2 (retirement) deliberately get new plans
against the trees that actually land from this phase.

## Global constraints

- Run every direct Mix command as
  `export PATH="$(mise where elixir)/bin:$PATH" && mix ...`. Do not substitute
  plain `mise exec -- mix`; it can select the wrong Elixir and false-fail.
- If a dependency compile silently rebuilds Vix without `jxlsave`, repair both
  environments before interpreting JXL failures:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH"
  mix deps.get
  VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix --force
  MIX_ENV=test mix deps.get
  MIX_ENV=test VIX_COMPILATION_MODE=PLATFORM_PROVIDED_LIBVIPS mix deps.compile vix --force
  ```

- TDD is binding. Run the focused test before implementation and record the
  expected RED. A ported test must prove it can fail through pre-port RED or a
  temporary production mutation, then pass after restoration.
- The parser implementation is frozen after the oracle-prerequisite commit.
  Phase-1 production edits under `lib/image_pipe/parser/twic_pics/**` are not
  allowed. Test harnesses may select either arm.
- Never use a differential re-bake to fix local code. After Task 2, fixture
  bytes, sources, manifest, and report are frozen through the rest of this
  plan.
- Preserve literal manipulation order. No helper may sort, group, rebuild, or
  map-collapse a TwicPics chain. Phase 1 does not implement the shadow rewrite;
  the quarantined shadowing case must remain exactly wrong on both local arms.
- Every arm gets separately initialized config, source/cache probes, counters,
  and a unique per-test telemetry prefix. Do not share mutable state between
  arms.
- Do not add a generic dialect runner or any core dependency on TwicPics.
- Do not add a TwicPics path to an ExDNA whole-file ignore. Use definition-level
  suppression only where ExDNA reports an intentional phase-1 mirror.
- Keep `.credo.exs` and `mise.toml` ExDNA file-ignore lists byte-for-byte
  equivalent as sets.
- Run `mise run precommit` after each major batch and at the exit gate. Fiddle
  is not migrated in phase 1, so `precommit:fiddle` is not expected here. If an
  incidental fiddle change appears, do not commit `fiddle/mix.lock`.
- Subagents may read, edit their assigned files, and run tests. They must not
  stash, reset, checkout, rebase, rename branches, commit, or otherwise mutate
  shared git state. The primary agent owns commits.
- The live bake and its provenance judgment run inline, not in a subagent. It
  uses network services, can upload a source, and requires inspecting returned
  metadata before continuing.
- Before the first push, rename the detached/random branch to a descriptive
  non-`codex` name such as `feat/twicpics-dialect-inversion-phase1`. Do not move
  the worktree directory.
- Resolve the oracle phase-base commit by exact subject and require one match.
  Do not use `git rev-list -1 --grep`, which silently chooses one of multiple
  matches:

  ```bash
  phase_subject='TwicPics oracle prerequisite: shadowing and no-enlarge baseline'
  phase_base_matches=$(git log --format='%H%x09%s' HEAD | awk -F '\t' -v subject="$phase_subject" '$2 == subject {print $1}')
  phase_base_count=$(printf '%s\n' "$phase_base_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$phase_base_count" -ne 1 ]; then
    printf 'expected one phase-base commit, found %s:\n%s\n' "$phase_base_count" "$phase_base_matches" >&2
    exit 1
  fi
  phase_base="$phase_base_matches"
  ```

## Execution shape

Recommended execution is subagent-driven by major batch, with the primary agent
integrating sequentially:

1. Run Tasks 1–2 inline because they mutate the oracle baseline and use live
   network services.
2. Task 3 (Response helper) and the initial analysis for Task 4 (ExDNA reports)
   may be reviewed independently, but land sequentially before any TwicPics
   copy.
3. Tasks 5–7 are a mechanical grammar/request batch; use a mechanical worker
   for exact copies and a design-capable reviewer for the ordered-step seam.
4. Tasks 8–10 are parity-critical pipeline/identity/lifecycle work. Keep their
   implementation and review at the highest available reasoning tier.
5. Tasks 11–14 build the nets and may be divided by harness, contract/error,
   and architecture/documentation boundaries after Task 10 is green.
6. Run one final parallel whole-branch review with disjoint architecture,
   real-TwicPics compatibility, and evidence/verification lenses.

Each task ends in a primary-agent commit. The exact commit subjects below are
stable resumption anchors; a worker can locate the last completed task with
`git log --oneline` even after context compaction or an LLM handoff.

---

### Task 1: Make the hosted-source handshake fail closed and testable

**Files:**

- Create:
  `test/support/image_pipe/test/twicpics_differential/source_hosting.ex`
- Create:
  `test/image_pipe/twicpics_differential/source_hosting_test.exs`
- Create:
  `test/image_pipe/twicpics_differential/gen_fixtures_test.exs`
- Modify: `test/support/mix/tasks/twicpics.gen_fixtures.ex`
- Modify:
  `test/support/image_pipe/test/twicpics_differential/README.md`

**Interface:** Extract source resolution from the Mix task into
`ImagePipe.Test.TwicpicsDifferential.SourceHosting.resolve!/3`. Its third
argument is an injected environment map used by tests and the Mix task:

```elixir
%{
  upload: (Path.t(), map() -> {source_bytes_url, hosted_url}),
  fetch: (String.t() -> {:ok, binary()} | {:error, term()}),
  info: (String.t() -> :ok)
}
```

Production `upload` sends the file to catbox, keeps the returned direct
`https://files.catbox.moe/...` URL as `source_bytes_url`, and derives the
`https://imagepipe.twic.pics/...` URL as `hosted_url`.

The state machine is closed:

- both inventory URLs present: first validate that they are HTTPS URLs on
  `files.catbox.moe` and `imagepipe.twic.pics`, with no userinfo, port, query,
  or fragment, and with the same non-empty basename. Download
  `source_bytes_url` and compare SHA-256 to the committed source. Then request
  `hosted_url <> "?twic=v1/output=png"`, decode that TwicPics identity render,
  and compare dimensions, bands, and exact pixels with the decoded committed
  source before returning the source record;
- both absent: upload once, print both exact inventory values, and raise before
  any fixture-oracle request or manifest write;
- exactly one present: raise as an incomplete handshake before upload, fixture
  fetch, or manifest write;
- a prior manifest URL never completes or overrides inventory metadata.

Make the task orchestration callable as `run_with/2`; `run/1` delegates to it
with the production environment. The injected environment has these explicit
side-effect seams in addition to the `SourceHosting` environment:

```elixir
%{
  source_entries: (-> [map()]),
  source_root: Path.t(),
  source_hosting: source_hosting_env,
  fetch_oracle: (case_map, sources -> {body, server_header}),
  write_fixture: (Path.t(), binary() -> :ok),
  write_manifest: (Path.t(), map() -> :ok),
  write_report: (map() -> :ok),
  prune_orphans: (map() -> :ok)
}
```

Tests may call `run_with/2`; it is test-support tooling, not a library export.
Production supplies `SourceInventory.all/0` and the committed source directory;
tests supply entries plus a temporary source root so they can exercise complete,
absent, and half-complete inventory states without changing repository data.
Source verification completes before fixture selection or any of the five
downstream callbacks can run.

- [ ] **Step 1: Write RED tests.** Cover complete metadata, both-absent
  bootstrap, only-`hosted_url`, only-`source_bytes_url`, remote-byte mismatch,
  wrong hosts/schemes, query/fragment/userinfo/port rejection, mismatched
  basenames, a hosted identity render with wrong dimensions/bands/pixels, and
  upload failure. Spies must assert the two incomplete states never invoke the
  hosted identity or fixture-oracle callback and never write a manifest. Run:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH" && mix test \
    test/image_pipe/twicpics_differential/source_hosting_test.exs \
    test/image_pipe/twicpics_differential/gen_fixtures_test.exs
  ```

  Expected RED: `SourceHosting` is undefined.

- [ ] **Step 2: Implement the extraction.** Keep file writes and fixture fetches
  in `Mix.Tasks.Twicpics.GenFixtures`; `SourceHosting` returns verified source
  records only. Delete the current `entry.hosted_url || recorded_url || upload`
  fallback and the nil-URL success path.

- [ ] **Step 3: Prove the hosted identity and abort boundaries.** Write the
  `run_with/2` orchestration RED test before changing `run/1`. A complete
  source must fetch in this order: direct Catbox bytes, TwicPics identity render,
  then fixture transformations. Compare decoded pixels, not encoded bytes,
  because the committed source can be WebP while the identity render is pinned
  PNG. Add a task-level test seam or callback spy showing a bootstrap/incomplete
  result stops before the identity request, `fetch_oracle!/2`,
  `Manifest.write!/2`, `write_report!/1`, and orphan pruning. Also show an
  identity mismatch stops before the first fixture transformation and every
  write/prune operation.

- [ ] **Step 4: Document the two-run workflow.** The first run uploads and
  aborts with two values; the engineer records both in `SourceInventory`; the
  second run verifies direct bytes and the TwicPics identity render before the
  first fixture transformation. Remove the old claim that a missing
  `hosted_url` can flow through the same bake.

- [ ] **Step 5: Gate and commit.** Run the focused tests, source-inventory
  tests, `mix format --check-formatted`, and `mix credo --strict`.

  ```bash
  git add test/support/image_pipe/test/twicpics_differential/source_hosting.ex \
    test/image_pipe/twicpics_differential/source_hosting_test.exs \
    test/image_pipe/twicpics_differential/gen_fixtures_test.exs \
    test/support/mix/tasks/twicpics.gen_fixtures.ex \
    test/support/image_pipe/test/twicpics_differential/README.md
  git commit -m "TwicPics oracle: fail-closed two-run source handshake"
  ```

---

### Task 2: Add the two oracle cases, correct conformance docs, and freeze the phase base

> **Inline/environmental task.** This task uses GitHub and the live TwicPics
> SaaS. Obtain approval for external state changes if the execution session
> does not already authorize them.

**Files:**

- Modify:
  `test/support/image_pipe/test/twicpics_differential/constellations.ex`
- Add two PNGs under
  `test/support/image_pipe/test/twicpics_differential/fixtures/`
- Modify:
  `test/support/image_pipe/test/twicpics_differential/manifest.exs`
- Modify: `test/support/image_pipe/test/twicpics_differential/REPORT.md`
- Modify:
  `test/support/image_pipe/test/twicpics_differential/README.md`
- Modify: `docs/twicpics_support_matrix.md`
- Test: `test/image_pipe/twicpics_differential/constellations_test.exs`
- Test: `test/image_pipe/twicpics_differential_conformance_test.exs`

**Cases:**

```elixir
# Names are fixed so later plans and reports have stable selectors.
%{id: "resize_shadow_relative_then_absolute", chain: "resize=50p/resize=340", ...}
%{id: "resize_no_enlarge", chain: "resize=600", verdict: :equal, ...}
```

Create a dedicated GitHub issue for the shadowing incompatibility before
authoring the triage map, then store its returned issue number in the triage
metadata. Do not reuse #323 or #457: they track the differential suite and
core-helper work, not this behavioral gap.

- [ ] **Step 1: Add assertion-level census tests before editing prose.** In
  `constellations_test.exs`, assert total, `:equal`, `:diverges`, and `:triage`
  counts from `Constellations.all/0`; assert every `:triage` has a non-empty
  reason and positive issue number, and every `:diverges` has its two-sided
  band. Expected pre-change census: 37 total, 5 `:diverges`, 0 `:triage`.

- [ ] **Step 2: Create the tracking issue and author the two cases.** The
  shadow case is `verdict: :equal` plus `triage: %{reason: ..., issue: n}`;
  `resize_no_enlarge` is ordinary `:equal`. The new expected census is 39
  total, 5 `:diverges`, 1 `:triage`.

- [ ] **Step 3: Bake only the new IDs.** First confirm the working tree contains
  only the intended authored/tooling changes. Then run:

  ```bash
  mise run twic:bake -- --only resize_shadow_relative_then_absolute,resize_no_enlarge
  ```

  If the mise task does not forward `--`, use the required direct-Mix form:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH" && MIX_ENV=test mix twicpics.gen_fixtures --only resize_shadow_relative_then_absolute,resize_no_enlarge
  ```

  Review the live URLs and `REPORT.md`; do not run `--force`.

- [ ] **Step 4: Record discriminating oracle evidence.** Decode the two new
  fixtures and assert 340×340 for the shadow case and 400×400 for no-enlarge.
  Fetch the direct `resize=340/output=png` URL once without writing it to the
  repository and compare its SHA-256 with the shadow fixture. Render the
  shadow chain locally through `Parser.TwicPics` and show it differs from the
  fixture; render `resize=600` locally and show it passes the ordinary verdict.
  Save the commands and hashes in the commit message or task report.

- [ ] **Step 5: Correct both conformance documents.** State 39 fixtures, five
  monitored divergences, and one quarantine. Name all five divergences: the
  two fractional `cover=2:3` cases and the three transparent-letterbox-under-
  shrink cases. Add the invisible RGB-under-alpha explanation to the
  `inside=W:H` ratio row, record live 404 versus ImagePipe 400 for negative
  focus, change shadowing from “optimization” to a behavioral divergence, and
  record plain-resize no-enlarge without claiming support for `resize-min`.

- [ ] **Step 6: Run the oracle gates.** The default differential lane passes
  with the shadow case excluded. Running that case explicitly must fail only
  against the local arm for the documented shadowing reason:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential/constellations_test.exs test/image_pipe/twicpics_source_inventory_test.exs
  export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential_conformance_test.exs
  export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/twicpics_differential_conformance_test.exs --include twicpics_triage --only twicpics_triage
  ```

- [ ] **Step 7: Run Vale, precommit, and commit the phase base.** Use the repo's
  configured Vale command/task discovered from `mise tasks` or config. Then:

  ```bash
  mise run precommit
  git add docs/twicpics_support_matrix.md \
    test/support/image_pipe/test/twicpics_differential/README.md \
    test/support/image_pipe/test/twicpics_differential/constellations.ex \
    test/support/image_pipe/test/twicpics_differential/fixtures \
    test/support/image_pipe/test/twicpics_differential/manifest.exs \
    test/support/image_pipe/test/twicpics_differential/REPORT.md \
    test/image_pipe/twicpics_differential/constellations_test.exs
  git commit -m "TwicPics oracle prerequisite: shadowing and no-enlarge baseline"
  ```

Later tasks resolve this phase-base by the exact-subject, exactly-one-match
snippet in Global constraints. The final exit report persists the resolved hash
as durable handoff evidence.

---

### Task 3: Complete #457's Response-to-Representation header seam

**Files:**

- Modify: `lib/image_pipe/response/cache_headers.ex`
- Modify: `lib/image_pipe/response.ex`
- Modify: `lib/image_pipe/dialect/native.ex`
- Modify: `lib/image_pipe/dialect/imgproxy.ex`
- Create: `test/image_pipe/response/cache_headers_test.exs`
- Modify: `test/image_pipe/dialect/native_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

**Interface:**

```elixir
@spec from_representation(ImagePipe.Representation.t()) :: t()
def from_representation(%ImagePipe.Representation{} = representation)
```

It returns `%CacheHeaders{etag: representation.etag,
representation_headers: vary_headers(representation.vary),
headers: Representation.response_headers(representation)}`. Vary is empty for
`[]` and one `{"vary", Enum.join(names, ", ")}` tuple otherwise.

- [ ] **Step 1: Write RED tests.** Cover strong ETag, no-store/no-ETag,
  empty Vary, multiple Vary names in supplied order, and unchanged
  `host_cache_control?/1`. Expected RED: `from_representation/1` undefined.

- [ ] **Step 2: Add the one-way Boundary edge.** `ImagePipe.Response` gains
  `ImagePipe.Representation` in `deps:`. Add an architecture assertion for
  Response → Representation and a reverse-edge refutation.

- [ ] **Step 3: Migrate Native and imgproxy.** Replace each private
  `cache_headers/1` call with `CacheHeaders.from_representation/1`. Every
  complete-body terminal, including Native BlurHash, constructs the shared
  value and applies both `.representation_headers` and `.headers`. Delete both
  private `cache_headers` and `vary_headers` definitions cleanly. Add a Native
  BlurHash regression test proving configured storage-header identity emits the
  corresponding `Vary`; this intentionally corrects the currently omitted
  header.

- [ ] **Step 4: Verify the seam and bounded header correction.** Run the new
  unit test, BlurHash regression, both dialect suites, cache/conditional tests,
  and architecture test. All observables remain unchanged except the missing
  BlurHash `Vary` fixed in Step 3. Then run `mise run precommit`.

- [ ] **Step 5: Commit.**

  ```bash
  git add lib/image_pipe/response/cache_headers.ex lib/image_pipe/response.ex \
    lib/image_pipe/dialect/native.ex lib/image_pipe/dialect/imgproxy.ex \
    test/image_pipe/response/cache_headers_test.exs \
    test/image_pipe/dialect/native_test.exs \
    test/image_pipe/architecture_boundary_test.exs
  git commit -m "Core: build cache headers from Representation (#457)"
  ```

---

### Task 4: Restore ExDNA visibility before adding the third dialect

**Files:**

- Modify: `.credo.exs`
- Modify: `mise.toml`
- Create: `test/image_pipe/ex_dna_ignore_parity_test.exs`
- Modify only as reported:
  `lib/image_pipe/dialect/native.ex`,
  `lib/image_pipe/dialect/native/pipeline.ex`,
  `lib/image_pipe/dialect/imgproxy.ex`,
  `lib/image_pipe/dialect/imgproxy/pipeline.ex`

- [ ] **Step 1: Remove the four dialect paths from both whole-file ignore
  lists.** Leave the four unrelated core exclusions intact. Rewrite the nearby
  comments to describe the resulting four entries; do not leave historical
  “eight entry” narration.

- [ ] **Step 2: Run both duplication detectors RED.** Capture every reported
  definition and pair:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH" && mix credo --strict
  export PATH="$(mise where elixir)/bin:$PATH" && mix ex_dna --exclude-macro alias --ignore lib/image_pipe/decode.ex --ignore lib/image_pipe/decode/source_format.ex --ignore lib/image_pipe/dialect/shared_config.ex --ignore lib/image_pipe/response/conditional.ex
  ```

- [ ] **Step 3: Add definition-level suppression only to irreducible product
  chain mirrors.** Use `# ex_dna:disable-for-next-line` immediately before the
  reported `def`/`defp`. Do not suppress a helper that Task 3 just made shared;
  do not suppress a whole module/file; do not pre-suppress likely future
  reports.

- [ ] **Step 4: Verify list parity mechanically.** Add an ExUnit test that
  evaluates `.credo.exs`, locates the `{ExDNA.Credo, options}` check, extracts
  its `:ignore` list, and extracts every non-whitespace token immediately after
  `--ignore` from the `mix ex_dna` command in `mise.toml`. Normalize each side
  only with `Enum.sort/1`; assert each raw list has no duplicates and the sorted
  path lists are exactly equal. Run:

  ```bash
  export PATH="$(mise where elixir)/bin:$PATH" && mix test test/image_pipe/ex_dna_ignore_parity_test.exs
  ```

  Both detectors and `mise run precommit` must also pass.

- [ ] **Step 5: Commit.**

  ```bash
  git add .credo.exs mise.toml lib/image_pipe/dialect/native.ex \
    lib/image_pipe/dialect/native/pipeline.ex \
    lib/image_pipe/dialect/imgproxy.ex \
    lib/image_pipe/dialect/imgproxy/pipeline.ex \
    test/image_pipe/ex_dna_ignore_parity_test.exs
  git commit -m "ExDNA: restore definition visibility for dialect chains (#457)"
  ```

---

### Task 5: Add the TwicPics boundary anchor, flat config, and canonical request types

**Files:**

- Create: `lib/image_pipe/dialect/twic_pics.ex` (Boundary/Plug stub only)
- Create: `lib/image_pipe/dialect/twic_pics/config.ex`
- Create: `lib/image_pipe/dialect/twic_pics/request.ex`
- Create: `test/image_pipe/dialect/twic_pics/config_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/request_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

**Boundary:** `ImagePipe.Dialect.TwicPics` is top-level with the same inward
toolkit set required by the final chain:

```elixir
deps: [
  ImagePipe.Cache,
  ImagePipe.Config,
  ImagePipe.Debug,
  ImagePipe.Decode,
  ImagePipe.Delivery,
  ImagePipe.Dialect.SharedConfig,
  ImagePipe.Error,
  ImagePipe.Format,
  ImagePipe.Output,
  ImagePipe.Plan,
  ImagePipe.Representation,
  ImagePipe.Response,
  ImagePipe.Source,
  ImagePipe.Telemetry,
  ImagePipe.Transform
]
```

It exports nothing. Architecture tests explicitly reject Parser, Request,
Resolver, Renderer, and other product-dialect dependencies.

**Config:** `Config.validate!/1` splits one flat keyword list into:

- `SharedConfig.keys/0`;
- `ImagePipe.Config.keys/0`, resolved with an empty TwicPics overlay;
- dialect keys `:storage_inputs`, `:detector`, `:detector_required`, and
  `:allow_debug_headers`.

The last four use the framework defaults and validation shapes: `[]`,
`:default`, `false`, and `false`. `storage_inputs` delegates each entry to
`SharedConfig.validate_storage_input/1`. Unknown/nested `twicpics:` keys raise
at init.

**Request:**

```elixir
@enforce_keys [:source, :steps, :output, :response, :auto_rotate]
defstruct @enforce_keys

@type step ::
        {:set_focus, ImagePipe.Transform.Focus.operand()}
        | :set_auto_focus
        | {:operation, ImagePipe.Plan.Pipeline.operation()}
        | {:focused, ImagePipe.Plan.Pipeline.operation()}
```

`:focused` means “this semantic operation consumes the guide active at this
position”; it is not a shared Plan marker. The operation carries a benign
center guide as typed construction data; Task 8's late-bound neutral helper
doesn't interpret that guide. `Request` contains
no raw `{name, args}` pair, `Directive`, `:deferred`, resolver module, conn,
PID, or reference.

- [ ] **Step 1: Write config RED tests.** Test defaults, flat neutral quality,
  all shared runtime keys, each dialect key, malformed storage inputs,
  malformed detector/debug values, unknown keys, and rejection of the old
  nested `twicpics:` shape.

- [ ] **Step 2: Add the boundary stub and config.** `TwicPics.init/1` delegates
  to `Config.validate!/1`; `call/2` may raise `NotImplementedError` only until
  Task 10. Compile after this task so every subsequent namespace module belongs
  to the correct Boundary.

- [ ] **Step 3: Add the request struct/type.** Tests construct every step form
  and assert the struct term contains none of the forbidden strategy vocabulary.

- [ ] **Step 4: Add the initial architecture assertions.** Pin exact deps and
  exports, plus “core does not name TwicPics.” The Plan-construction AST gate
  lands in Task 13 once the namespace has real modules to scan.

- [ ] **Step 5: Gate and commit.** Run the two focused tests, architecture test,
  compile with warnings as errors, and Credo/ExDNA.

  ```bash
  git add lib/image_pipe/dialect/twic_pics.ex \
    lib/image_pipe/dialect/twic_pics/config.ex \
    lib/image_pipe/dialect/twic_pics/request.ex \
    test/image_pipe/dialect/twic_pics/config_test.exs \
    test/image_pipe/dialect/twic_pics/request_test.exs \
    test/image_pipe/architecture_boundary_test.exs
  git commit -m "Dialect.TwicPics: boundary, flat config, ordered request types"
  ```

---

### Task 6: Copy the leaf grammar with both copies live

**Files:**

- Create exact semantic copies under `lib/image_pipe/dialect/twic_pics/`:
  `manipulation.ex`, `units.ex`, `output.ex`, `source.ex`, `path.ex`
- Create corresponding tests under
  `test/image_pipe/dialect/twic_pics/`:
  `manipulation_test.exs`, `units_test.exs`, `output_test.exs`,
  `source_test.exs`, `path_test.exs`
- Create:
  `test/image_pipe/dialect/twic_pics/leaf_grammar_parity_test.exs`

Copy from `lib/image_pipe/parser/twic_pics/**`, changing only namespace-local
aliases. Preserve tagged errors, exact rational arithmetic, JSON-number grammar,
round-half-away behavior, zero-based coordinates, percent/scale units, path
decoding, and top-level slash splitting.

- [ ] **Step 1: Copy the existing tests first and point them at undefined
  dialect modules.** Include every case from the four existing leaf test files;
  add direct `Source.from_segments/1` coverage because it was previously reached
  only through Path. Run the new directory and record undefined-module RED.

- [ ] **Step 2: Copy the five modules mechanically.** Do not “clean up” parser
  behavior in the copy. Do not share a grammar module across product boundaries;
  the legacy copy disappears in phase 2.

- [ ] **Step 3: Add a cross-copy corpus.** For representative success and error
  values from every public leaf function, assert legacy result equals dialect
  result as a complete term. Include malformed/nested arithmetic, exponent
  extremes, mixed units, URI decoding, unsupported versions, formats, and
  quality bounds.

- [ ] **Step 4: Resolve ExDNA reports at definition scope.** Suppress only the
  exact copied definitions ExDNA reports as intentional transition mirrors.
  Add no file ignore.

- [ ] **Step 5: Gate and commit.** Run old and new leaf suites together,
  compile, Credo, ExDNA, and precommit.

  ```bash
  git add lib/image_pipe/dialect/twic_pics/{manipulation,units,output,source,path}.ex \
    test/image_pipe/dialect/twic_pics
  git commit -m "Dialect.TwicPics: copy ordered leaf grammar with dual coverage"
  ```

---

### Task 7: Replace PlanBuilder with a dialect-local ordered RequestBuilder

**Files:**

- Create: `lib/image_pipe/dialect/twic_pics/request_builder.ex`
- Create: `test/image_pipe/dialect/twic_pics/request_builder_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/parse_test.exs`
- Modify: `lib/image_pipe/dialect/twic_pics.ex` only to add an internal parse
  composition used by later lifecycle work

**Interface:**

```elixir
@spec build(Plan.Source.t(), [{String.t(), String.t()}], keyword()) ::
        {:ok, Dialect.TwicPics.Request.t()} | {:error, term()}
```

The fold remains left-to-right. Normal operations become
`{:operation, op}`. `cover` size/ratio and guided `crop` become
`{:focused, op_with_center_guide}`. Literal/coordinate focus becomes
`{:set_focus, operand}`; `focus=auto` becomes `:set_auto_focus`. Output,
quality, and debug retain last-value-wins accumulation outside the pixel-step
list. The builder applies neutral output config and stores `%Plan.Response{}`
and `auto_rotate`, but never creates `%Plan{}`, `%Directive{}`, `:deferred`, or
a resolver field.

- [ ] **Step 1: Port all 25 PlanBuilder cases as RED request/step assertions.**
  Each port names the legacy test it replaces eventually. Assertions inspect
  ordered steps rather than a Plan pipeline. The relative-resize case must still
  contain two separate steps; no shadow optimizer exists in phase 1.

- [ ] **Step 2: Implement RequestBuilder as a semantic copy.** Preserve
  error terms and last-wins behavior. A focused operation's neutral center guide
  is construction data only; the `:focused` tag is the product-local decision.

- [ ] **Step 3: Compose Path → Manipulation → RequestBuilder.** Keep this as a
  dialect-internal function called by `TwicPics.call/2` later. Test missing
  `twic`, bad version, malformed segment, unsupported transform, and a valid
  ordered request. Every rejection must happen without a source/cache adapter.

- [ ] **Step 4: Add invariant tests.** Recursively scan every produced Request
  for `ImagePipe.Plan`, `Directive`, `:deferred`, and `ImagePipe.Resolver`; assert
  none occur. Assert the two order-discriminating chains produce different
  ordered request terms.

- [ ] **Step 5: Gate and commit.** Run legacy PlanBuilder plus new builder/parse
  tests, Credo, ExDNA, and precommit.

  ```bash
  git add lib/image_pipe/dialect/twic_pics/request_builder.ex \
    lib/image_pipe/dialect/twic_pics.ex \
    test/image_pipe/dialect/twic_pics/request_builder_test.exs \
    test/image_pipe/dialect/twic_pics/parse_test.exs
  git commit -m "Dialect.TwicPics: ordered RequestBuilder without Plan markers"
  ```

---

### Task 8: Move focus carry into PointFlow and the local pipeline

**Files:**

- Create: `lib/image_pipe/dialect/twic_pics/point_flow.ex`
- Create: `lib/image_pipe/dialect/twic_pics/pipeline.ex`
- Modify: `lib/image_pipe/transform/neutral_resolver.ex`
- Modify: `test/image_pipe/transform/neutral_resolver_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/point_flow_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/pipeline_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/decode_preflight_test.exs`

**PointFlow interface:** `PointFlow` is also its private carry struct:

```elixir
defstruct guide: :point, point: nil

@type t :: %__MODULE__{
        guide: :point | {:smart, :face_assist},
        point: ImagePipe.Transform.Focus.point() | nil
      }

init/0
set_focus/3       # resolve operand against the running SourceShape
set_auto/1        # change guide mode; preserve the carried point, matching legacy
resolve/3         # shape + flow + {:operation | :focused, op}
continue/4        # local measured-seam continuation
```

For a `:focused` step under point mode, call a new narrow neutral helper:

```elixir
NeutralResolver.resolve_late_bound_guide(shape, operation)
```

This helper supports only the two neutral guide consumers TwicPics can emit
(`CropGuided` and cover-mode `Resize`). It applies the existing pending-
orientation box swap and odd-pixel `center_bias`, but skips concrete
gravity/offset remapping because PointFlow binds the storage-frame point
afterward. It returns ordinary executable ops and the ordinary neutral
continuation with no `:deferred` value in either the semantic operation or the
result. PointFlow then substitutes the emitted executable crop gravity with the
concrete point **after** orientation compensation.

This helper is required for exact behavior: sending a benign center guide
through `NeutralResolver.resolve/3` would remap it as a concrete display-frame
anchor. That collapses the current nil-focus odd-pixel behavior into explicit
`focus=center` under a pending quarter turn, violating the existing wire pin.
Don't reproduce that bug and don't smuggle `:deferred` into the local pipeline.

For smart mode, put `{:smart, :face_assist}` onto the semantic operation before
ordinary neutral resolution and carry the existing point through the
pixel-selected crop unchanged. The returned continuation is local data; it
never uses `ImagePipe.Resolver` dispatch or exposes resolver carry vocabulary.

Point advancement copies the current explicit rules: measured resize scaling,
crop translation, canvas embed translation, pending-orientation reflection/
rotation, and an enumerated point/dimension-neutral operation set. Unknown
reachable operations raise.

**Pipeline interface:**

```elixir
decode_request(Request.t(), SourceGeometry.t()) :: DecodePlanner.Request.t()
run(State.t(), SourceGeometry.t(), Request.t(), keyword()) ::
  {:ok, State.t()} | {:error, {:transform, term()} | {:decode, term()}}
```

One request is one pipeline scope: seed shape and PointFlow once, execute every
step in order, flush orientation once at the request boundary. It includes the
same input-color-management preamble/stamp as Native and imgproxy. Its local
follow loop has a finite continuation-depth cap and uses test seams
`:chain`, `:measure_dims`, and `:continue` only in pipeline tests.
Before the first semantic step, resolve the configured detector with
`ImagePipe.Transform.resolve_detector/1` and seed both the detector and
`detector_required` policy onto State, matching the imgproxy pipeline.

- [ ] **Step 1: Port Resolver/PointFlow tests RED.** Port all 12 existing tests
  to the local interface: set/overwrite focus, nil-center fallback, staged cover,
  pending orientation, smart pass-through, known neutral op, and fail-closed
  unknown/Trim/Padding. Add `focus=auto` preserving the old carried point and a
  later literal focus replacing it.

- [ ] **Step 2: Add the late-bound neutral helper RED/GREEN.** In
  `neutral_resolver_test.exs`, compare it with the current `:deferred` strategy
  path for CropGuided and cover Resize under no orientation, half turns, and
  quarter turns. After PointFlow binds nil/concrete points, executable ops,
  continuation shapes, odd-pixel center bias, and realized crop rectangles must
  match. Reject unsupported operation kinds loudly. Implement the helper by
  extracting the existing private compensation decisions, not by copying the
  whole resolver branch.

- [ ] **Step 3: Implement PointFlow without the strategy SDK.** Compare emitted
  executable ops, shape, and point with the legacy Resolver for the same
  operation corpus. This is phase-1 evidence only; don't import or call legacy
  code from production.

- [ ] **Step 4: Write Pipeline RED tests.** Cover ordered relative resizes,
  focus before/after resize, multiple consumers, region crop, canvas, EXIF flush,
  two measured resize seams, empty steps, chain failure tagging, color carry,
  and active `focus=auto` with configured, disabled, and required-but-missing
  detectors. Assert pixel and detector-telemetry parity with the framework arm.
  Use a genuinely streamed source for at least one real execution case.

- [ ] **Step 5: Implement the ordered driver.** Overlay State from SourceShape
  exactly once before resolving/executing each semantic operation. Never
  re-overlay between that operation's continuation stages: each tail consumes
  the State returned by its preceding stage. Follow continuations after
  measuring the realized image, update PointFlow at the same seam, and flush
  once. Resolve and seed detector state before entering this loop.

- [ ] **Step 6: Make decode preflight converge with the legacy op-chain path.**
  Stop at the first resize step unconditionally, ignoring focus-only steps but
  never skipping a relative/no-pixel resize to use a later absolute resize.
  Derive its target and preceding crop extent; if that first resize has no
  pixel target, return `nil`, not `{nil, nil}`. Table/property tests compare
  `DecodePlanner.open_options_for/5` from the new request with
  `DecodePlanner.open_options/5` over the equivalent legacy Plan operations for
  JPEG/WebP, portrait/landscape, px/relative axes, crop-before-resize, repeated
  resizes, no geometry, and the direct convergence case
  `resize=50p/resize=340`. Phase 1 intentionally matches the unoptimized literal
  stream, including that quarantined shadow chain.

- [ ] **Step 7: Prove the ports are load-bearing.** Temporarily remove one crop
  translation rule and one seam-scale update; show the respective tests fail,
  restore, and record the RED/GREEN commands.

- [ ] **Step 8: Gate and commit.** Run legacy and local Resolver/PointFlow,
  pipeline/preflight, sequential-access, orientation, and color-carry tests;
  then precommit.

  ```bash
  git add lib/image_pipe/dialect/twic_pics/{point_flow,pipeline}.ex \
    lib/image_pipe/transform/neutral_resolver.ex \
    test/image_pipe/transform/neutral_resolver_test.exs \
    test/image_pipe/dialect/twic_pics/{point_flow,pipeline,decode_preflight}_test.exs
  git commit -m "Dialect.TwicPics: pipeline-local focus carry and ordered execution"
  ```

---

### Task 9: Add ordered identity, output negotiation, and protocol errors

**Files:**

- Create: `lib/image_pipe/dialect/twic_pics/identity.ex`
- Create: `lib/image_pipe/dialect/twic_pics/negotiation.ex`
- Create: `lib/image_pipe/dialect/twic_pics/errors.ex`
- Create: `test/image_pipe/dialect/twic_pics/identity_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/negotiation_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/errors_test.exs`

**Identity:** `Identity.material/5` takes Request, Negotiation, conn, config, and
the resolved detector identity. `representation` contains the canonical ordered steps,
auto-rotate, negotiated selection, canonical output intent/policy material, and
detector identity only when smart focus can affect pixels. `storage_only`
contains `Representation.storage_inputs/2`; there is no TwicPics cachebuster.
The dialect behavior epoch starts `{ImagePipe.Dialect.TwicPics, 1}`. Recursive
struct canonicalization retains each struct's module discriminator. Never sort
steps.

`Request.face_assist?/1` (or an Identity-private fold) simulates guide mode over
the ordered steps: it returns true only when a `:focused` step executes while
`focus=auto` is active before a later literal focus replaces it.

**Negotiation:** Use the same `%Negotiation{selected, vary?, policy_material,
policy}` invariant as the other image dialects. Build one Policy from the
Request's `%Plan.Output{}`, call `Policy.ensure_capable/2`, normalize
`identity_selection/1`, and carry that exact Policy into final
`Output.Negotiate.negotiate_output/4`.

**Errors:** Preserve TwicPics parser failures as status 400 and body
`invalid image request: #{inspect(reason)}`. Route source/decode/input-limit,
unsupported-output, encode/session, materialization, and transform failures
through `Response.ErrorStatus` using the same rewraps as the existing dialects.
Post-negotiation errors carry Policy headers; pre-negotiation errors do not.

- [ ] **Step 1: Write identity RED tests.** Prove reordered manipulation steps
  differ; equivalent normalized arithmetic/ratios match; debug metadata is
  excluded; output selection and detector identity affect key/ETag; storage
  header/cookie values affect key but not ETag; header names enter Vary and
  cookies do not.

- [ ] **Step 2: Implement canonical identity.** Add definition-level ExDNA
  suppression only if the recursive canonicalizer is reported as an intentional
  mirror of imgproxy.

- [ ] **Step 3: Write and implement negotiation tests.** Cover explicit output,
  automatic Accept selection, source-negotiated fallback, unsupported configured
  capability, and exact policy object reuse.

- [ ] **Step 4: Write and implement the error matrix.** Pin status, body, Vary
  headers, and materialization-as-decode behavior. Unknown parse reasons must not
  fall through to a generic 500; unknown core failures must not masquerade as
  parse 400s.

- [ ] **Step 5: Gate and commit.** Run focused tests, material-digest/cache-key
  tests, output-policy tests, Response error tests, Credo/ExDNA, and precommit.

  ```bash
  git add lib/image_pipe/dialect/twic_pics/{identity,negotiation,errors}.ex \
    test/image_pipe/dialect/twic_pics/{identity,negotiation,errors}_test.exs
  git commit -m "Dialect.TwicPics: ordered identity, negotiation, and errors"
  ```

---

### Task 10: Assemble the self-contained TwicPics Plug lifecycle

**Files:**

- Modify: `lib/image_pipe/dialect/twic_pics.ex`
- Create: `test/image_pipe/dialect/twic_pics/lifecycle_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/debug_test.exs`

**Visible chain:** method/CORS → parse → static detector/geometry checks →
source resolve → output-policy selection → detector identity → Representation
→ conditional 304 → cache lookup → `Delivery.stream/5` → `Decode.with_image/4`
→ `Pipeline.run/4` → `Output.Negotiate.negotiate_output/4` → clamp → delivery
materialization → first-chunk-forced encode → send.

Mirror the established core lifecycle, not a product runner abstraction:

- `OPTIONS` uses `Response.CORS.send_options/2`; non-GET/HEAD uses
  `Response.Sender.send_method_not_allowed/1`.
- `Telemetry.Trace.maybe_extract_inbound/1` and CORS registration happen before
  the request span.
- Parse/static failures occur before `Source.resolve/3`, cache lookup, or fetch.
- `Representation.build/3` and a non-wildcard conditional 304 happen before
  cache lookup/fetch.
- `If-None-Match: *` succeeds only on a cache hit.
- `internal_cache: :disabled` skips both lookup and write.
- Cache errors fail open; only successful encoded responses commit.
- Response metadata is built from the current Request for both hit and miss.
- `CacheHeaders.from_representation/1` owns ETag/Vary/no-store packaging.
- `Delivery.StreamPull.first_chunk/1` is forced inside the `[:encode]` span;
  mid-stream failure keeps the existing committed-response behavior.
- Clamp limits are the tighter of host `max_result_*` and encoder limits.
- Transform failures are rescued/tagged only around the lazy libvips build
  boundary, matching existing dialect behavior; trusted parser callbacks are
  not rescued.

**Debug:** Build a product-neutral `%ImagePipe.Debug.Info{}` from the facts the
dialect already owns (SourceGeometry, source/output formats, final dimensions,
quality/search metadata, ordered operation names, and measured stage timings).
Partial unavailable source facts stay `nil`; do not copy Request-private
helpers merely to fill optional fields. Pass the Info through Delivery so both
miss and cache-hit debug paths work. Set `debug?: request.response.debug? and
config[:allow_debug_headers]` only at delivery; debug remains absent from
identity.

- [ ] **Step 1: Write lifecycle RED tests using source/cache spies.** Cover
  valid GET, HEAD, OPTIONS, 405, CORS on 200/304/4xx, parse no-fetch/no-cache,
  conditional 304, cache miss/hit, internal-cache disabled, cache read/write
  failure, source/decode/input-limit failure, unsupported output, result clamp,
  and current response metadata on a hit.

- [ ] **Step 2: Implement route/parse/prefetch chain.** Use a private `[:parse]`
  span with stable stop metadata. Compute detector identity once before
  Representation; TwicPics has only face-assist smart focus, so strict detector
  availability remains aligned with the framework's current classes-only gate
  in phase 1 while identity includes face assist.

- [ ] **Step 3: Implement serve/cache/generate.** Use Delivery and Decode
  brackets exactly as the other inverted dialects do. Call the TwicPics
  pipeline, shared final negotiation, clamp, materializer, and encoder.

- [ ] **Step 4: Add debug RED/GREEN.** Cover debug=1 with allow true, no segment,
  allow false, debug=0, invalid debug before fetch, miss headers, and cached-hit
  replay. Exclude timing values from exact comparisons; assert presence/type and
  semantic facts.

- [ ] **Step 5: Add request/transform/encode/send telemetry spans.** Use the
  standard event names and result/error metadata. Because Logger and OTel
  already subscribe to these shared stage names, no subscription-list change is
  expected; prove both surfaces still see the events before deciding no docs
  update is needed.

- [ ] **Step 6: Resolve ExDNA reports at definition scope.** The third visible
  chain will resemble Native/imgproxy. Suppress only exact irreducible mirrors;
  if a reported block is a product-neutral decision, stop and extract that
  decision instead of suppressing it.

- [ ] **Step 7: Gate and commit.** Run all dialect TwicPics tests, existing
  dialect suites, Delivery/Decode/Response tests, telemetry Logger/Capture tests,
  and precommit.

  ```bash
  git add lib/image_pipe/dialect/twic_pics.ex \
    test/image_pipe/dialect/twic_pics/lifecycle_test.exs \
    test/image_pipe/dialect/twic_pics/debug_test.exs
  git commit -m "Dialect.TwicPics: self-contained Plug lifecycle"
  ```

---

### Task 11: Dual-run all TwicPics wire conformance

**Files:**

- Modify: `test/image_pipe/twic_pics_wire_conformance_test.exs`
- Create only if the compile-time loop is unwieldy:
  `test/support/image_pipe/test/twic_pics_wire_contract.ex`

- [ ] **Step 1: Normalize every call site while framework-only.** Route all 49
  current tests through one `call/3` helper, including the inline Accept request.
  This is a verification checkpoint inside the Task 11 commit, not a separate
  commit: the framework suite stays 49 tests and passes before adding an arm.

- [ ] **Step 2: Parameterize two modules.** Prefer the imgproxy compile-time
  `for {arm, suffix} <- ...` pattern. If module attributes/setup make that
  fragile, use one shared `__using__` contract and two thin modules. The
  framework arm calls `ImagePipe.Plug`; the dialect arm calls
  `ImagePipe.Dialect.TwicPics`.

  `translate_opts/1` must:

  - drop `:parser`;
  - hoist the nested `:twicpics` neutral keyword into the flat dialect config;
  - pass SharedConfig, detector, detector-required, and debug keys;
  - translate non-empty cache `key_headers`/`key_cookies` into
    `storage_inputs` while leaving cache-adapter config intact;
  - initialize each arm independently on every test setup.

- [ ] **Step 3: Prove dialect-arm reachability, then run GREEN.** After
  parameterization, temporarily replace the dialect call with a deliberate 500
  and require the dialect copies to fail while the 49 framework copies remain
  green. Restore the call, then require all 98 generated base cases to pass; a
  naturally green first real run is valid. Fix production, not assertions, for
  any real failure. Later shared-contract additions increase the final count,
  so derive that count from the authored cases rather than pinning 98.

- [ ] **Step 4: Add missing representative lifecycle cases to the shared
  contract.** Add HEAD, OPTIONS/405, CORS, strong ETag 304-before-fetch, cache
  hit and cache-disabled, storage header/cookie identity, detector-identity
  change for active `focus=auto`, max input pixels, and a private-prefix
  telemetry smoke case. These run on both arms. Do not assert order
  insensitivity; add an explicit assertion that the two existing
  focus/resize orderings remain pixel-different within each arm.

- [ ] **Step 5: Compare cross-arm observables where deterministic.** For a
  representative PNG, JPEG, auto-negotiated response, parse error, 304, HEAD,
  cache hit, and debug response, compare status, content type, decoded
  dimensions/pixels, ETag/Vary/cache-control, and stable debug headers. Compare
  raw bodies only for deterministic explicit-PNG cases; never compare timing
  values.

- [ ] **Step 6: Gate and commit.** Run the dual suite twice (once seeded), the
  focused dialect suite, and precommit.

  ```bash
  git add test/image_pipe/twic_pics_wire_conformance_test.exs \
    test/support/image_pipe/test/twic_pics_wire_contract.ex
  git commit -m "TwicPics wire conformance: dual-run framework and dialect"
  ```

  Omit the optional support file from `git add` if it was not created.

---

### Task 12: Dual-run the SaaS differential and add a zero-divergence local net

**Files:**

- Modify:
  `test/support/image_pipe/test/twicpics_differential/harness.ex`
- Modify: `test/image_pipe/twicpics_differential_conformance_test.exs`
- Create: `test/image_pipe/twicpics_cross_arm_conformance_test.exs`

The shared differential harness already supports opaque `{plug, initialized_opts}`
arms. Add `plug_opts(:framework | :dialect)` in the TwicPics wrapper, retain
`plug_opts/0` as framework for bake/diagnose/report tooling during phase 1, and
thread literal `Constellations.twicpics_path/1` unchanged to both arms.

- [ ] **Step 1: Dual-run each arm against the SaaS fixture.** Generate the
  verdict test for both arms. Manifest/source drift tests remain single because
  they test the oracle, not a stack. Expected default render count is 38
  non-triaged constellations × 2 after Task 2; derive/assert the count from the
  authored census rather than hardcoding it in test generation.

- [ ] **Step 2: Run the default lane.** Every dialect failure is a code bug. Do
  not reauthor tolerance, change verdict, widen a band, or bake.

- [ ] **Step 3: Add the exact local cross-arm test over all 39 constellations,
  including the quarantined shadow case.** For each literal path, build fresh
  arms and assert status, content type, dimensions, bands, and exact pixel
  equality (zero differing band samples). Also assert raw body SHA-256 equality
  for a named deterministic subset spanning order, focus carry, ratio crop,
  inside transparency, and arithmetic. If bytes differ while pixels match,
  classify and name the case; do not weaken pixel exactness.

- [ ] **Step 4: Add harness self-checks for order.** Show the two authored
  focus-before/after-resize paths remain different within the framework and
  within the dialect. This proves the harness did not normalize the chain while
  still requiring each path to match cross-arm.

- [ ] **Step 5: Prove the cross-arm test can fail.** Temporarily reverse steps
  only in the dialect test seam or mutate one PointFlow translation; capture RED,
  restore, and rerun GREEN.

- [ ] **Step 6: Prove fixture freeze and tooling compatibility.** Bake/diagnose/
  report modules still compile against `plug_opts/0`. Run:

  ```bash
  phase_subject='TwicPics oracle prerequisite: shadowing and no-enlarge baseline'
  phase_base_matches=$(git log --format='%H%x09%s' HEAD | awk -F '\t' -v subject="$phase_subject" '$2 == subject {print $1}')
  phase_base_count=$(printf '%s\n' "$phase_base_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$phase_base_count" -ne 1 ]; then
    printf 'expected one phase-base commit, found %s:\n%s\n' "$phase_base_count" "$phase_base_matches" >&2
    exit 1
  fi
  phase_base="$phase_base_matches"
  git diff --exit-code "$phase_base" -- \
    test/support/image_pipe/test/twicpics_differential/fixtures \
    test/support/image_pipe/test/twicpics_differential/sources \
    test/support/image_pipe/test/twicpics_differential/manifest.exs \
    test/support/image_pipe/test/twicpics_differential/REPORT.md
  export PATH="$(mise where elixir)/bin:$PATH" && mix test \
    test/image_pipe/twicpics_differential_conformance_test.exs \
    test/image_pipe/twicpics_cross_arm_conformance_test.exs
  ```

- [ ] **Step 7: Gate and commit.** Run precommit; no fixture path may be staged.

  ```bash
  git add test/support/image_pipe/test/twicpics_differential/harness.ex \
    test/image_pipe/twicpics_differential_conformance_test.exs \
    test/image_pipe/twicpics_cross_arm_conformance_test.exs
  git commit -m "TwicPics differential: both arms against SaaS plus exact local net"
  ```

---

### Task 13: Add dialect contracts, error paths, telemetry equivalence, and hard architecture gates

**Files:**

- Create: `test/image_pipe/dialect/twic_pics_contract_test.exs`
- Create: `test/image_pipe/dialect/twic_pics/error_paths_test.exs`
- Create: `test/image_pipe/twic_pics_telemetry_contract_test.exs`
- Modify: `test/image_pipe/architecture_boundary_test.exs`

- [ ] **Step 1: Instantiate both dialect contract kits.** Use
  `ImagePipe.ContractKit.CacheKey` and `RequestSafety` with TwicPics paths.
  Cache equivalence groups use normalized arithmetic and ratios, never URL
  reordering. Include explicit/automatic negotiation, an explicit PNG as the
  fixed-content-type case, and storage header/cookie variants. Rejectable paths
  include missing `twic`, bad version, malformed arithmetic, unsupported
  transform, negative focus, and zero crop. The valid path is an explicit PNG.

- [ ] **Step 2: Port the nine-row inverted-dialect error matrix.** Use
  `test/image_pipe/dialect/native_error_paths_test.exs` as the behavior
  reference: origin 5xx, owner disconnect during fetch, decode reject,
  transform failure with cleanup, encoder failure after first chunk, cache
  lookup raise, cache write failure, producer cancel, and response already
  sent. Assert status/error taxonomy, sink commit/abort, and cleanup counts; do
  not copy Native URL semantics.

- [ ] **Step 3: Add telemetry equivalence on both local arms.** Scenarios:
  cache miss, hit, conditional 304, parse error, streamed error after prepare,
  and owner cancellation. Each uses an isolated private prefix and handler.
  Compare semantic stage names/order and result/error metadata. Do not compare
  PIDs, span counts caused by topology, durations, or raw trace IDs.

- [ ] **Step 4: Add a syntax-aware Plan-construction gate.** Parse every `.ex`
  under `lib/image_pipe/dialect/twic_pics/**` with `Code.string_to_quoted!/1`,
  collect alias bindings per lexical scope, and reject both `%Plan{}` and
  `%ImagePipe.Plan{}` struct construction. Include self-tests that fixtures with
  each spelling fail the checker while `%Plan.Output{}` and neutral operation
  structs pass. A regex-only test is insufficient.

- [ ] **Step 5: Complete boundary/reference gates.** Assert exact TwicPics deps
  and no exports; scan core boundaries for `ImagePipe.Dialect.TwicPics`; scan
  the dialect for Parser/Request/Resolver/Renderer and other dialect references;
  scan Request/Source/Response for concrete transform operations as existing
  architecture rules require.

- [ ] **Step 6: Gate and commit.** Run all four files, Logger/Capture telemetry
  tests, Boundary compile, Credo/ExDNA, and precommit.

  ```bash
  git add test/image_pipe/dialect/twic_pics_contract_test.exs \
    test/image_pipe/dialect/twic_pics/error_paths_test.exs \
    test/image_pipe/twic_pics_telemetry_contract_test.exs \
    test/image_pipe/architecture_boundary_test.exs
  git commit -m "Dialect.TwicPics: contracts, error matrix, telemetry, architecture gates"
  ```

---

### Task 14: Sync docs, inventory future test retirement, and prove the phase-1 exit gate

**Files:**

- Modify: `docs/twicpics_support_matrix.md`
- Create: `.superpowers/sdd/twicpics-phase1-test-inventory.md`
- Create: `.superpowers/sdd/twicpics-phase1-exit-criteria.md`

**Documentation:** Rewrite architectural descriptions from
`Plan`/`Directive`/`Resolver`/`:deferred` to the dialect's ordered Request,
PointFlow, and Pipeline. Keep the framework arm explicitly identified as the
temporary phase-1 comparison arm. Do not claim the shadowing gap is fixed; it
remains quarantined for phase 2 wave 1. Update surface/stage/behavior axes only
where this phase changed them.

**Inventory:** Classify every file/case under these locations for phase 2 wave
2:

- `test/parser/twic_pics/**`
- `test/image_pipe/parser/twic_pics/**`
- all remaining `Parser.TwicPics` references in `test/`, `fiddle/`, docs, and
  Mix tasks
- cache-key/resolver-version assertions and custom-parser-guide strategy text

Each entry uses one of these dispositions and its matching evidence fields:

- `PORT`: product behavior moves to a dialect-owned test; cite the destination
  and record its pre-port RED or a temporary production-mutation RED.
- `REPOINT`: product-neutral framework coverage survives but calls the dialect
  after retirement; cite the surviving test and the replacement entry point,
  and record as a Phase 2 acceptance requirement that the repointed test must
  fail when that entry point is replaced with a deliberate failure.
- `DELETE`: the case is redundant after retirement; cite the surviving
  equivalent coverage and state what unique behavior analysis found (none).
  Deletion does not require an artificial mutation when the surviving citation
  already proves the behavior.

This task records future work only; it performs no retirement.

- [ ] **Step 1: Write the inventory.** Include all 25 PlanBuilder cases, 12
  Resolver/PointFlow cases, leaf grammar cases, 49 original wire cases, generic
  framework cases, fiddle mount, bake parse gate, diagnose/report helpers,
  cache-key strategy version pins, and documentation references.

- [ ] **Step 2: Sync the support matrix and run Vale.** Remove stale claims that
  the only TwicPics implementation is a compatibility parser or that product
  focus state lives in shared Plan vocabulary. Retain the live behavior and
  accepted-divergence descriptions from Task 2.

- [ ] **Step 3: Write the exit report.** Check every phase-1 criterion from the
  spec with file/test/commit evidence: dual wire, dual SaaS, exact cross-arm,
  order discrimination, config/cache/source isolation, telemetry isolation,
  lifecycle representatives, dependency inversion, frozen oracle paths, Vale,
  and precommit. Resolve and record the actual phase-base hash.

- [ ] **Step 4: Run the full evidence gate.** At minimum:

  ```bash
  phase_subject='TwicPics oracle prerequisite: shadowing and no-enlarge baseline'
  phase_base_matches=$(git log --format='%H%x09%s' HEAD | awk -F '\t' -v subject="$phase_subject" '$2 == subject {print $1}')
  phase_base_count=$(printf '%s\n' "$phase_base_matches" | sed '/^$/d' | wc -l | tr -d ' ')
  if [ "$phase_base_count" -ne 1 ]; then
    printf 'expected one phase-base commit, found %s:\n%s\n' "$phase_base_count" "$phase_base_matches" >&2
    exit 1
  fi
  phase_base="$phase_base_matches"
  git diff --exit-code "$phase_base" -- \
    test/support/image_pipe/test/twicpics_differential/fixtures \
    test/support/image_pipe/test/twicpics_differential/sources \
    test/support/image_pipe/test/twicpics_differential/manifest.exs \
    test/support/image_pipe/test/twicpics_differential/REPORT.md
  export PATH="$(mise where elixir)/bin:$PATH" && mix test \
    test/image_pipe/twic_pics_wire_conformance_test.exs \
    test/image_pipe/twicpics_differential_conformance_test.exs \
    test/image_pipe/twicpics_cross_arm_conformance_test.exs \
    test/image_pipe/twic_pics_telemetry_contract_test.exs \
    test/image_pipe/architecture_boundary_test.exs
  mise run precommit
  ```

  Also run the repository's Vale gate. If JXL fails with
  `Failed to write VipsImage to buffer`, repair Vix exactly as listed in Global
  constraints and rerun; do not touch fixtures.

- [ ] **Step 5: Final whole-branch parallel review.** Required reviewers:

  1. architecture/boundary and host-parser future-retirement safety;
  2. real TwicPics compatibility using official llms docs and the hosted SaaS,
     with special attention to zero-based coordinates, running dimensions,
     order, and the quarantined shadow rule;
  3. evidence discipline: RED proofs, dual-arm reachability, frozen oracle,
     tolerance/quarantine conventions, telemetry isolation, and deletion
     inventory.

  Apply accepted findings, rerun affected focused tests, Vale, and precommit.

- [ ] **Step 6: Commit the phase-1 closeout.**

  ```bash
  git add docs/twicpics_support_matrix.md \
    .superpowers/sdd/twicpics-phase1-test-inventory.md \
    .superpowers/sdd/twicpics-phase1-exit-criteria.md
  git commit -m "TwicPics dialect phase 1: docs and exit evidence"
  ```

**Stop after this commit.** Do not implement shadowing, change the parser,
migrate fiddle/bake consumers, retire the framework arm, or remove the strategy
SDK. Those are phase 2 wave 1 and wave 2, planned against the landed dual-run
tree.

## Plan self-review notes

- **Spec coverage:** oracle handshake/baseline → Tasks 1–2; T7/#457 → Tasks
  3–4; flat config and dependency inversion → Task 5; grammar copy → Task 6;
  ordered request/no markers → Task 7; local D5 carry/decode preflight → Task 8;
  ordered identity/output/errors → Task 9; complete Plug → Task 10; wire D2 →
  Task 11; SaaS + exact D2 → Task 12; contracts/telemetry/architecture → Task
  13; docs, deletion inventory, and exit evidence → Task 14.
- **Type consistency:** the request step union uses existing exported neutral
  types (`Focus.operand`, Plan operation structs, Plan Output/Response/Source)
  but never the root Plan struct. PointFlow owns its carry type. Negotiation owns
  the one Policy used for identity and final resolution.
- **Order consistency:** every parsing, request, identity, execution, wire, and
  differential step preserves the literal list. Only phase 2 may add the one
  upstream-proven shadow rewrite.
- **Placeholder scan:** no task depends on a guessed issue number or commit hash.
  The shadow issue is created before authoring its triage metadata; the phase
  base is resolved by its fixed commit subject.
- **Known risk:** debug source facts are richer on the framework path because its
  private Processor sees the seekable input. Phase 1 requires parity for stable
  exposed behavior, but the dialect must not widen core solely to populate
  optional, currently unasserted Info fields. Any observable missing header is
  a recorded phase-2 stack gap, not silently ignored.
- **Known sequencing risk:** Task 10 is the first complete lifecycle and Task 11
  is the first full wire integration. Tasks 6–9 provide smaller RED/GREEN nets
  so integration failures can be localized.
- **Deliberate phase boundary:** the oracle prerequisite is in this plan because
  it must precede and freeze the copy. Gap closure and retirement are excluded
  because their line-level plans depend on the actual phase-1 divergences and
  test inventory.
