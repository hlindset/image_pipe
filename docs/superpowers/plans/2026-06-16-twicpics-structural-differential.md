# TwicPics structural differential suite — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A standing, no-network conformance suite that verifies `ImagePipe.Parser.TwicPics` reproduces live TwicPics' geometry/placement, asserting decoded colour-grid structure (dims + bands + cell-map) rather than pixels.

**Architecture:** Live hosted TwicPics is the bake-time oracle; the default `mix test` lane compares ImagePipe's re-derived structural record against committed records (hybrid: record is the gate, reference PNG is for debug). A shared `ImagePipe.Test.Differential.*` namespace is extracted from the imgproxy suite (manifest serializer, render harness, heatmap renderer, report shell) and both suites route through it. The bake is an incremental network task driven by an oracle signature; sources are hosted on catbox via the existing TwicPics catch-all path.

**Tech Stack:** Elixir, ExUnit, `Vix.Vips.Image`/`Image`, `Plug.Test`, `Req`, `Boundary`, mix tasks under `test/support/mix/tasks/`.

**Spec:** [`docs/superpowers/specs/2026-06-16-twicpics-structural-differential-design.md`](../specs/2026-06-16-twicpics-structural-differential-design.md)

---

## File structure

**Shared (extracted from imgproxy suite):**
- Create `test/support/image_pipe/test/differential/manifest_term.ex` — `ImagePipe.Test.Differential.ManifestTerm`
- Create `test/support/image_pipe/test/differential/harness.ex` — `ImagePipe.Test.Differential.Harness`
- Create `test/support/image_pipe/test/differential/heatmap.ex` — `ImagePipe.Test.Differential.Heatmap`
- Create `test/support/image_pipe/test/differential/report_shell.ex` — `ImagePipe.Test.Differential.ReportShell`
- Modify imgproxy `manifest.ex`, `harness.ex`, `imgproxy.gen_report.ex`, `report_html.ex` to delegate.

**TwicPics suite (`test/support/image_pipe/test/twicpics_differential/`):**
- `source_inventory.ex`, `constellations.ex`, `manifest.ex`, `structure_compare.ex`, `harness.ex`, `report_html.ex`, `sources/` (committed PNGs), `fixtures/` (committed reference PNGs), `manifest.exs`, `REPORT.md`, `README.md`.

**Mix tasks (`test/support/mix/tasks/`):**
- `twicpics.gen_fixtures.ex`, `twicpics.diagnose.ex`, `twicpics.gen_report.ex`, `twicpics.reauthor.ex`

**Tests:**
- `test/image_pipe/twicpics_differential_conformance_test.exs`
- `test/image_pipe/twicpics_source_inventory_test.exs`
- `test/support/image_pipe/test/differential/*_test.exs` (for extracted shared logic)

**Other:**
- `test/test_helper.exs` (add `:twicpics_triage`, `:twicpics_report` excludes)
- `mix.exs` (`preferred_envs` for the four `twicpics.*` tasks)
- `mise.toml` (`twic:bake` task)
- `.gitignore` (twicpics `report.html`)
- `docs/twicpics_support_matrix.md` (differential-suite note)

---

## Phase 1 — Shared extraction: ManifestTerm + Harness

These two are the clean, low-risk extractions the TwicPics suite directly depends on. Refactor imgproxy onto them and keep its suite green before building anything new.

### Task 1: Extract `Differential.ManifestTerm`

**Files:**
- Create: `test/support/image_pipe/test/differential/manifest_term.ex`
- Create: `test/support/image_pipe/test/differential/manifest_term_test.exs`
- Modify: `test/support/image_pipe/test/imgproxy_differential/manifest.ex`

- [ ] **Step 1: Write the failing test**

```elixir
# test/support/image_pipe/test/differential/manifest_term_test.exs
defmodule ImagePipe.Test.Differential.ManifestTermTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.Differential.ManifestTerm

  test "sorted_map_literal renders nested maps with sorted keys" do
    out = ManifestTerm.sorted_map_literal(%{"b" => %{z: 1, a: 2}, "a" => 3})
    assert out == ~s|%{"a" => 3,"b" => %{a: 2,z: 1}}|
  end

  test "authored_sha256 is stable across key order and ignores absent keys" do
    keys = [:chain, :verdict]
    a = ManifestTerm.authored_sha256(%{verdict: :equal, chain: "x", extra: 9}, keys)
    b = ManifestTerm.authored_sha256(%{chain: "x", verdict: :equal}, keys)
    assert a == b and byte_size(a) == 64
  end

  test "file_sha256 hashes bytes (lowercase hex)" do
    path = Path.join(System.tmp_dir!(), "mt_#{System.unique_integer([:positive])}.bin")
    File.write!(path, "abc")
    assert ManifestTerm.file_sha256(path) ==
             "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mise exec -- mix test test/support/image_pipe/test/differential/manifest_term_test.exs`
Expected: FAIL — `ImagePipe.Test.Differential.ManifestTerm` undefined.

- [ ] **Step 3: Create the module**

Move the pure serialization/hash helpers out of imgproxy `manifest.ex` (`render` body's `sorted_map_literal`, `pair_literal`, `value_literal`, plus `file_sha256`) into the shared module. `authored_sha256` becomes key-list-parametrized (imgproxy currently hardcodes `@authored_keys`).

```elixir
# test/support/image_pipe/test/differential/manifest_term.ex
defmodule ImagePipe.Test.Differential.ManifestTerm do
  @moduledoc """
  Shared, suite-neutral serialization + hashing for differential manifests
  (imgproxy, TwicPics). Renders a git-diffable, `mix format`-stable Elixir term
  with deterministically key-sorted maps (so a manifest stays diffable past
  `inspect`'s 32-key small-map sorting limit), and computes the authored-field and
  file hashes. Each suite keeps its own `validate!`/entry shape and the top-level
  `render/1` that names its provenance fields.
  """
  use Boundary, top_level?: true, deps: []

  @doc "Pretty-print a sorted map literal string for `map` (recurses into nested maps)."
  @spec sorted_map_literal(map()) :: String.t()
  def sorted_map_literal(map) do
    body =
      map
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map_join(",", fn {key, value} -> pair_literal(key, value) end)

    "%{#{body}}"
  end

  defp pair_literal(key, value) when is_atom(key), do: "#{key}: #{value_literal(value)}"
  defp pair_literal(key, value), do: "#{inspect(key)} => #{value_literal(value)}"

  defp value_literal(map) when is_map(map), do: sorted_map_literal(map)
  defp value_literal(value), do: inspect(value, limit: :infinity, printable_limit: :infinity)

  @doc """
  Run a full manifest body string through the real formatter and write it to
  `path` (so the committed file matches `mix format`). `body` is the suite's
  top-level `%{...}` literal built with `sorted_map_literal/1`.
  """
  @spec write!(Path.t(), String.t()) :: :ok
  def write!(path, body) when is_binary(body) do
    File.mkdir_p!(Path.dirname(path))
    formatted = body |> Code.format_string!() |> IO.iodata_to_binary()
    File.write!(path, formatted <> "\n")
  end

  @doc """
  Stable, field-order-independent hash of `keys` pulled from `term` (missing keys
  read as `nil`). Uses deterministic `term_to_binary` so nested-map values hash
  canonically across VM invocations.
  """
  @spec authored_sha256(map(), [atom()]) :: String.t()
  def authored_sha256(term, keys) do
    canonical = Enum.map(keys, fn k -> {k, Map.get(term, k)} end)

    :crypto.hash(:sha256, :erlang.term_to_binary(canonical, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc "SHA-256 (lowercase hex) of a file's bytes."
  @spec file_sha256(Path.t()) :: String.t()
  def file_sha256(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)
end
```

- [ ] **Step 4: Refactor imgproxy `manifest.ex` to delegate**

In `test/support/image_pipe/test/imgproxy_differential/manifest.ex`: add `alias ImagePipe.Test.Differential.ManifestTerm`. Replace the private `sorted_map_literal/pair_literal/value_literal` with calls to `ManifestTerm.sorted_map_literal/1`; change `write!/2` to build the body string (the current `render/1` output) and call `ManifestTerm.write!(path, body)`; delegate `file_sha256/1` to `ManifestTerm.file_sha256/1`; change `authored_sha256/1` to `ManifestTerm.authored_sha256(constellation, @authored_keys)`. Keep `load!/validate!/validate_entry!` and `@authored_keys` exactly as-is.

**Boundary note:** `manifest.ex` stays **unbounded** (no `use Boundary`, same as today). Calling into `ManifestTerm` (a `top_level?: true, deps: []` boundary) is ingress into that boundary's root module — allowed; Boundary only constrains a boundary's *outgoing* deps, and a `deps: []` boundary may still call external libs (`Image`/`Vix`). Do **not** add `check: [out: false]` to `Manifest` to "fix" a non-error. Reserve `check: [out: false]` for the mix tasks + harness that alias several sibling boundaries. The same applies to the TwicPics `Manifest` (Task 6).

- [ ] **Step 5: Run shared + imgproxy suite, verify green**

Run: `mise exec -- mix test test/support/image_pipe/test/differential/manifest_term_test.exs test/image_pipe/imgproxy_differential_conformance_test.exs`
Expected: PASS (imgproxy authored/source hashes unchanged — pure refactor).

- [ ] **Step 6: Commit**

```bash
git add test/support/image_pipe/test/differential/manifest_term.ex test/support/image_pipe/test/differential/manifest_term_test.exs test/support/image_pipe/test/imgproxy_differential/manifest.ex
git commit -m "refactor(differential): extract shared ManifestTerm serializer/hasher"
```

### Task 2: Extract `Differential.Harness`

**Files:**
- Create: `test/support/image_pipe/test/differential/harness.ex`
- Modify: `test/support/image_pipe/test/imgproxy_differential/harness.ex`

- [ ] **Step 1: Create the shared harness**

Generalize the imgproxy harness's plug wiring (read its current body at `harness.ex:25-81`). Parametrize by parser, sources spec, sources dir, and request path.

```elixir
# test/support/image_pipe/test/differential/harness.ex
defmodule ImagePipe.Test.Differential.Harness do
  @moduledoc """
  Shared live-render machinery for differential suites. Builds an `ImagePipe.Plug`
  pipeline that serves committed source bytes over a local function plug, so a
  suite's conformance test, report, and diagnose tasks all render identically.
  Suite-specific wrappers supply the parser and the per-case request path.
  """
  use Boundary, top_level?: true, check: [out: false]

  import Plug.Test
  alias ImagePipe.SourceTest.RootHTTPAdapter

  @doc "`ImagePipe.Plug` opts serving `sources_dir`'s files locally for `parser`."
  def plug_opts(parser, sources_dir) do
    ImagePipe.Plug.init(
      parser: parser,
      sources: [
        path:
          {RootHTTPAdapter,
           root_url: "http://origin.test", req_options: [plug: source_plug(sources_dir)]}
      ]
    )
  end

  @doc "Render `request_path` through `plug_opts` → `{body_bytes, content_type}`."
  def render(request_path, plug_opts) do
    conn = :get |> conn(request_path) |> ImagePipe.Plug.call(plug_opts)

    content_type =
      conn
      |> Plug.Conn.get_resp_header("content-type")
      |> List.first()
      |> then(fn ct -> ct && ct |> String.split(";") |> List.first() end)

    {conn.resp_body, content_type}
  end

  @doc "Render `request_path` to a decoded `Vix.Vips.Image` (random access)."
  def render_image(request_path, plug_opts) do
    {body, _ct} = render(request_path, plug_opts)
    Image.open!(body, access: :random, fail_on: :error)
  end

  defp source_plug(sources_dir) do
    fn conn ->
      file = Path.basename(conn.request_path)

      conn
      |> Plug.Conn.put_resp_content_type(content_type(file))
      |> Plug.Conn.send_resp(200, File.read!(Path.join(sources_dir, file)))
    end
  end

  defp content_type(file) do
    case Path.extname(file) do
      ".jpg" -> "image/jpeg"
      ".webp" -> "image/webp"
      _ -> "image/png"
    end
  end
end
```

- [ ] **Step 2: Refactor imgproxy `harness.ex` to wrap it**

Keep `ImagePipe.Test.ImgproxyDifferential.Harness` and its public functions (`plug_opts/0`, `render/2`, `render_image/2`, `fixture_path/1`, `fixture_image/1`) — the imgproxy conformance test + 3 tasks call these. Reimplement the render trio over the shared harness:

```elixir
alias ImagePipe.Test.Differential.Harness, as: Shared
alias ImagePipe.Test.ImgproxyDifferential.Constellations

def plug_opts, do: Shared.plug_opts(ImagePipe.Parser.Imgproxy, @sources_dir)
def render(constellation, plug_opts \\ plug_opts()),
  do: Shared.render(Constellations.imgproxy_path(constellation), plug_opts)
def render_image(constellation, plug_opts \\ plug_opts()),
  do: Shared.render_image(Constellations.imgproxy_path(constellation), plug_opts)
```

Keep `fixture_path/1` and `fixture_image/1` as they are (they read the imgproxy fixtures dir). Remove the now-dead private `source_plug/1`, `content_type/1`, and the `RootHTTPAdapter`/`Plug.Test` imports.

- [ ] **Step 3: Run imgproxy suite + report/diagnose smoke, verify green**

Run: `mise exec -- mix test test/image_pipe/imgproxy_differential_conformance_test.exs && mise exec -- mix imgproxy.diagnose rs_fit_zone`
Expected: conformance PASS; diagnose prints a line for `rs_fit_zone`.

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/test/differential/harness.ex test/support/image_pipe/test/imgproxy_differential/harness.ex
git commit -m "refactor(differential): extract shared render Harness (parser + path)"
```

---

## Phase 2 — TwicPics suite skeleton (no network)

Build and prove the gating machinery against hand-fed structural records before any bake, so the comparison logic is verified independently of the oracle.

### Task 3: `TwicpicsDifferential.StructureCompare` — cell-map extractor/comparator

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/structure_compare.ex`
- Create: `test/support/image_pipe/test/twicpics_differential/structure_compare_test.exs`

- [ ] **Step 1: Write the failing test**

Build a synthetic 4×4 grid image (same encoding as the source), extract its record, assert the identity cell-map; build a single-cell flat image and assert all samples decode to that cell; build an RGBA image with a transparent strip and assert `:padding`.

```elixir
# test/support/image_pipe/test/twicpics_differential/structure_compare_test.exs
defmodule ImagePipe.Test.TwicpicsDifferential.StructureCompareTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.StructureCompare, as: SC

  # cell (col,row) colour for a cols×rows grid: [chan(col,cols), chan(row,rows), 255]
  defp chan(_i, 1), do: 0
  defp chan(i, n), do: round(i * 255 / (n - 1))

  defp grid_image(cols, rows, cell) do
    base = Image.new!(cols * cell, rows * cell, color: [0, 0, 0])

    for col <- 0..(cols - 1), row <- 0..(rows - 1), reduce: base do
      acc ->
        c = Image.new!(cell, cell, color: [chan(col, cols), chan(row, rows), 255])
        Image.compose!(acc, c, x: col * cell, y: row * cell)
    end
  end

  @spec_4x4 %{cols: 4, rows: 4}

  test "identity grid decodes to the full cell-map at cell-centre lattice" do
    img = grid_image(4, 4, 40)
    rec = SC.extract(img, @spec_4x4)
    assert rec.dims == {160, 160}
    assert rec.bands == 3
    assert rec.cols == 4
    # cell-centre lattice (4×4) over an identity grid → each sample its own cell
    assert SC.cell_at(rec, 0, 0) == {:cell, {0, 0}}
    assert SC.cell_at(rec, 3, 3) == {:cell, {3, 3}}
    assert SC.cell_at(rec, 2, 1) == {:cell, {2, 1}}
  end

  test "uniform single-cell image: every sample is that cell" do
    img = Image.new!(50, 50, color: [170, 85, 255])  # col 2, row 1 of a 4×4
    rec = SC.extract(img, @spec_4x4)
    assert Enum.all?(rec.cells, &(&1 == {:cell, {2, 1}}))
  end

  test "transparent pixels decode as :padding" do
    img = Image.new!(40, 40, color: [0, 0, 0, 0], bands: 4)
    rec = SC.extract(img, @spec_4x4)
    assert Enum.all?(rec.cells, &(&1 == :padding))
    assert rec.bands == 4
  end

  test "compare/2 returns :match for equal records, structural diff otherwise" do
    a = %{dims: {10, 10}, bands: 3, cells: [{:cell, {0, 0}}, {:cell, {1, 1}}]}
    assert SC.compare(a, a) == :match
    b = %{a | cells: [{:cell, {0, 0}}, {:cell, {2, 2}}]}
    assert {:mismatch, diff} = SC.compare(a, b)
    assert diff.cells == [{1, {:cell, {1, 1}}, {:cell, {2, 2}}}]
  end

  test "low_confidence_samples flags none for a clean grid" do
    img = grid_image(4, 4, 40)
    assert SC.low_confidence_samples(img, @spec_4x4) == []
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/structure_compare_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the module**

```elixir
# test/support/image_pipe/test/twicpics_differential/structure_compare.ex
defmodule ImagePipe.Test.TwicpicsDifferential.StructureCompare do
  @moduledoc """
  The TwicPics structural comparator. Decodes a rendered colour-grid image to a
  structural record `%{dims, bands, cells}` and compares two records.

  The colour grid encodes content identity: cell (col,row) is
  `[chan(col,cols), chan(row,rows), 255]` with `chan(i,n) = round(i*255/(n-1))`.
  Sampling a fixed cell-centre lattice over the output and decoding each point to
  the nearest cell (or `:padding`/`:ambiguous`) yields a placement fingerprint
  that survives the foreign engine's resampling — so the gate is geometry, not
  pixels. Colour/alpha tolerance lives only here, inside the per-sample decode.
  """
  use Boundary, top_level?: true, deps: []

  @type cell :: {:cell, {non_neg_integer(), non_neg_integer()}} | :padding | :ambiguous
  @type record :: %{
          dims: {pos_integer(), pos_integer()},
          bands: pos_integer(),
          cols: pos_integer(),
          cells: [cell()]
        }

  # Default decode tolerances. `color_dist` is the max squared RGB distance (sum of
  # per-channel squared diffs, 0..3*255²) for a confident nearest-cell match; beyond
  # it a sample is :ambiguous. `alpha` is the max alpha (0..255) counted as padding.
  @default_tol %{color_dist: 1600, alpha: 16}
  def default_tol, do: @default_tol

  @doc """
  Extract the structural record from `image` for grid `spec` (%{cols, rows}). The
  record carries `cols` so `cell_at/3` can index the lattice for any grid shape.
  `compare/2` reads only dims/bands/cells, so the manifest stores those (not cols).
  """
  @spec extract(Vix.Vips.Image.t(), map(), map()) :: record()
  def extract(image, spec, tol \\ @default_tol) do
    w = Image.width(image)
    h = Image.height(image)
    bands = Image.bands(image)
    cells = Enum.map(lattice(spec), fn {fx, fy} -> elem(decode(image, w, h, fx, fy, spec, tol), 0) end)
    %{dims: {w, h}, bands: bands, cols: spec.cols, cells: cells}
  end

  @doc """
  Lattice indices (0-based) of samples whose nearest-cell distance is past the
  half-way mark to the `:ambiguous` threshold — the low-confidence-margin guard. A
  clean grid returns `[]`; any flagged index is the bake's signal to consider
  pinning `truecolor` or nudging the lattice (it is a diagnostic, never a gate).
  """
  @spec low_confidence_samples(Vix.Vips.Image.t(), map(), map()) :: [non_neg_integer()]
  def low_confidence_samples(image, spec, tol \\ @default_tol) do
    w = Image.width(image)
    h = Image.height(image)

    spec
    |> lattice()
    |> Enum.map(fn {fx, fy} -> decode(image, w, h, fx, fy, spec, tol) end)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{value, dist}, i} ->
      if match?({:cell, _}, value) and dist > tol.color_dist / 2, do: [i], else: []
    end)
  end

  @doc "Lattice index `(li, lj)` → decoded cell of `record` (row-major cols×rows)."
  @spec cell_at(record(), non_neg_integer(), non_neg_integer()) :: cell()
  def cell_at(%{cells: cells, cols: cols}, li, lj), do: Enum.at(cells, lj * cols + li)

  @doc """
  Compare two records. `:match` when dims, bands, and every cell agree; otherwise
  `{:mismatch, %{dims, bands, cells}}` where `cells` lists `{index, expected, got}`.
  """
  @spec compare(record(), record()) :: :match | {:mismatch, map()}
  def compare(expected, got) do
    cell_diffs =
      [expected.cells, got.cells]
      |> Enum.zip_reduce([], fn [e, g], acc -> [{e, g} | acc] end)
      |> Enum.reverse()
      |> Enum.with_index()
      |> Enum.flat_map(fn {{e, g}, i} -> if e == g, do: [], else: [{i, e, g}] end)

    diff =
      %{}
      |> put_if(:dims, expected.dims != got.dims, {expected.dims, got.dims})
      |> put_if(:bands, expected.bands != got.bands, {expected.bands, got.bands})
      |> put_if(:cells, cell_diffs != [], cell_diffs)

    if diff == %{}, do: :match, else: {:mismatch, diff}
  end

  # cell-centre lattice derived from the grid: fractions (i+0.5)/n. Stored row-major
  # (rows outer, cols inner) so cell_at/3 indexing matches.
  @doc false
  def lattice(%{cols: cols, rows: rows}) do
    fx = for i <- 0..(cols - 1), do: (i + 0.5) / cols
    fy = for j <- 0..(rows - 1), do: (j + 0.5) / rows
    for vy <- fy, vx <- fx, do: {vx, vy}
  end

  # Returns `{value, nearest_dist}` so the caller can both record the decoded value
  # and report decode confidence. `:padding`/`:ambiguous` carry a sentinel distance.
  defp decode(image, w, h, fx, fy, spec, tol) do
    x = min(round(fx * w), w - 1)
    y = min(round(fy * h), h - 1)
    px = Image.get_pixel!(image, x, y) |> Enum.map(&round/1)

    cond do
      length(px) == 4 and List.last(px) <= tol.alpha -> {:padding, 0}
      true -> nearest(Enum.take(px, 3), spec, tol)
    end
  end

  defp nearest([r, g, b], %{cols: cols, rows: rows}, tol) do
    {best, dist} =
      for(col <- 0..(cols - 1), row <- 0..(rows - 1), do: {col, row})
      |> Enum.map(fn {col, row} ->
        {cr, cg, cb} = {chan(col, cols), chan(row, rows), 255}
        {{col, row}, (cr - r) * (cr - r) + (cg - g) * (cg - g) + (cb - b) * (cb - b)}
      end)
      |> Enum.min_by(&elem(&1, 1))

    if dist <= tol.color_dist, do: {{:cell, best}, dist}, else: {:ambiguous, dist}
  end

  defp chan(_i, 1), do: 0
  defp chan(i, n), do: round(i * 255 / (n - 1))

  defp put_if(map, _key, false, _val), do: map
  defp put_if(map, key, true, val), do: Map.put(map, key, val)
end
```

- [ ] **Step 4: Run test, verify it passes**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/structure_compare_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/structure_compare.ex test/support/image_pipe/test/twicpics_differential/structure_compare_test.exs
git commit -m "feat(twicpics-diff): structural cell-map extractor + comparator"
```

### Task 4: Commit the seed source + `SourceInventory` + drift test

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/sources/grid_4x4.png` (downloaded hosted bytes)
- Create: `test/support/image_pipe/test/twicpics_differential/source_inventory.ex`
- Create: `test/image_pipe/twicpics_source_inventory_test.exs`

- [ ] **Step 1: Download and commit the hosted seed grid**

The oracle renders this exact byte stream, so commit precisely what is hosted (do **not** regenerate locally).

Run:
```bash
mkdir -p test/support/image_pipe/test/twicpics_differential/sources
curl -sS -o test/support/image_pipe/test/twicpics_differential/sources/grid_4x4.png https://files.catbox.moe/b7g72c.png
file test/support/image_pipe/test/twicpics_differential/sources/grid_4x4.png
```
Expected: `PNG image data, 400 x 400, 8-bit/color RGBA, non-interlaced`.

- [ ] **Step 2: Write the drift test (failing)**

```elixir
# test/image_pipe/twicpics_source_inventory_test.exs
defmodule ImagePipe.TwicpicsSourceInventoryTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, SourceInventory}

  @sources_dir "test/support/image_pipe/test/twicpics_differential/sources"

  test "every committed source has an inventory entry and vice versa" do
    on_disk = @sources_dir |> Path.join("*") |> Path.wildcard() |> Enum.map(&Path.basename/1) |> MapSet.new()
    inventoried = SourceInventory.all() |> Enum.map(& &1.file) |> MapSet.new()
    assert on_disk == inventoried
  end

  test "inventory facts match the decoded bytes" do
    for entry <- SourceInventory.all() do
      img = Image.open!(File.read!(Path.join(@sources_dir, entry.file)), access: :random, fail_on: :error)
      assert {Image.width(img), Image.height(img)} == {entry.width, entry.height}
      assert Image.bands(img) == entry.bands
      assert Vix.Vips.Image.format(img) == entry.format
      assert Image.interpretation(img) == entry.interpretation
    end
  end

  test "every constellation source is inventoried" do
    inv = SourceInventory.all() |> Enum.map(& &1.file) |> MapSet.new()
    for c <- Constellations.all(), do: assert(MapSet.member?(inv, Constellations.source_file(c)))
  end
end
```

- [ ] **Step 3: Run test, verify it fails**

Run: `mise exec -- mix test test/image_pipe/twicpics_source_inventory_test.exs`
Expected: FAIL — `SourceInventory`/`Constellations` undefined. (Constellations lands in Task 5; this test stays red until then — note it in the commit.)

- [ ] **Step 4: Implement `SourceInventory`**

```elixir
# test/support/image_pipe/test/twicpics_differential/source_inventory.ex
defmodule ImagePipe.Test.TwicpicsDifferential.SourceInventory do
  @moduledoc """
  Single source of truth for the committed TwicPics differential sources
  (`sources/`). Each entry records verifiable facts (dims/bands/format) plus its
  hosted URL (the bake oracle fetches this), how it is produced, and its
  invariant. Drift-checked by `test/image_pipe/twicpics_source_inventory_test.exs`.

  Sources are hosted on catbox and reached through the `imagepipe.twic.pics`
  catch-all path. The committed bytes MUST equal the hosted bytes (the bake
  verifies this), or ImagePipe and TwicPics render different inputs.
  """
  use Boundary, top_level?: true, deps: []

  @grid_4x4 %{cols: 4, rows: 4}

  @entries [
    %{
      file: "grid_4x4.png",
      hosted_url: "https://imagepipe.twic.pics/b7g72c.png",
      source_bytes_url: "https://files.catbox.moe/b7g72c.png",
      width: 400,
      height: 400,
      bands: 4,
      # Confirm `format`/`interpretation` against the decoded bytes during impl
      # (the drift test asserts them); `file` reports 8-bit RGBA, so UCHAR/sRGB.
      format: :VIPS_FORMAT_UCHAR,
      interpretation: :VIPS_INTERPRETATION_sRGB,
      grid: @grid_4x4,
      produced_by: "Colour grid from the #321 focus probe (tools/make_grid.exs), uploaded to catbox.",
      consumers: [:twicpics_differential],
      invariant:
        "4×4 cells of 100px; cell (col,row) = [chan(col,4),chan(row,4),255]. Decoding any " <>
          "output sample back to its cell is the placement gate. Opaque cells; alpha marks inside-letterbox padding."
    }
  ]

  @doc "All inventory entries."
  def all, do: @entries

  @doc "The grid spec (%{cols, rows}) for a source file."
  def grid(file), do: Enum.find(@entries, &(&1.file == file)).grid
end
```

- [ ] **Step 5: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/sources/grid_4x4.png test/support/image_pipe/test/twicpics_differential/source_inventory.ex test/image_pipe/twicpics_source_inventory_test.exs
git commit -m "feat(twicpics-diff): commit seed grid source + SourceInventory + drift test"
```

### Task 5: `Constellations` (full initial scope) + `Harness` wrapper

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/constellations.ex`
- Create: `test/support/image_pipe/test/twicpics_differential/harness.ex`
- Create: `test/support/image_pipe/test/twicpics_differential/constellations_test.exs`

- [ ] **Step 1: Write the failing test (parse + shape guarantees)**

Every chain must parse via the real TwicPics parser (fail fast, like imgproxy's parse gate), ids must be unique, and the request path must be well-formed.

```elixir
# test/support/image_pipe/test/twicpics_differential/constellations_test.exs
defmodule ImagePipe.Test.TwicpicsDifferential.ConstellationsTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.Constellations

  test "ids are unique" do
    ids = Enum.map(Constellations.all(), & &1.id)
    assert ids == Enum.uniq(ids)
  end

  test "twicpics_path builds the ?twic=v1 form with the pinned suffix" do
    c = %{id: "x", source: :grid_4x4, chain: "cover=200x100", verdict: :equal, group: :cover}
    assert Constellations.twicpics_path(c) == "/grid_4x4.png?twic=v1/cover=200x100/output=png/dpr=1"
  end

  test "every non-triaged chain parses via ImagePipe.Parser.TwicPics" do
    for c <- Constellations.all(), is_nil(c[:triage]) do
      assert {:ok, _plan} = parse(Constellations.twicpics_path(c)),
             "chain failed to parse: #{c.id} (#{c.chain})"
    end
  end

  # `ImagePipe.Parser.TwicPics.parse/2` takes (%Plug.Conn{}, opts); `Plug.Test.conn/2`
  # already populates path_info + the `twic` query param the parser reads.
  defp parse(path), do: ImagePipe.Parser.TwicPics.parse(Plug.Test.conn(:get, path), [])
end
```

Note: confirm the `ImagePipe.Parser.TwicPics.parse/2` arity/return against `lib/image_pipe/parser/twic_pics.ex` during implementation (reviewed as `(%Plug.Conn{}, opts) :: {:ok, plan} | {:error, _}`). `import Plug.Test` (or qualify) at the top of the test.

- [ ] **Step 2: Run test, verify it fails**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/constellations_test.exs`
Expected: FAIL — `Constellations` undefined.

- [ ] **Step 3: Implement `Constellations` (full initial scope)**

```elixir
# test/support/image_pipe/test/twicpics_differential/constellations.ex
defmodule ImagePipe.Test.TwicpicsDifferential.Constellations do
  @moduledoc """
  Authored TwicPics differential cases. Imported by BOTH the bake task and the
  conformance test so the two cannot drift. Each entry is authored intent
  (`id`, `source`, `chain`, `verdict`, `group`, optional `tol`/`triage`);
  provenance (dims/bands/cell-map/oracle signature/reference PNG) lives in the
  generated manifest, joined by `:id`. Every output is pinned `output=png/dpr=1`,
  no path-default manipulation.
  """
  use Boundary, top_level?: true, deps: []

  @source_files %{grid_4x4: "grid_4x4.png"}
  @suffix "output=png/dpr=1"

  @doc "Map of `source` atom -> committed source filename."
  def source_files, do: @source_files
  @doc "Committed source filename for a constellation."
  def source_file(%{source: source}), do: Map.fetch!(@source_files, source)
  @doc "The pinned request suffix (determinism pins)."
  def suffix, do: @suffix

  @doc "The TwicPics request path for a constellation (shared by bake + test)."
  def twicpics_path(%{source: source, chain: chain}),
    do: "/#{Map.fetch!(@source_files, source)}?twic=v1/#{chain}/#{@suffix}"

  @doc """
  The authored constellation list (full issue initial scope).

  Discrimination note: the source is square (400×400), so a SYMMETRIC consumer
  (`cover=NxN`, `contain=NxN`) on it is a pure uniform downscale — no crop, no
  letterbox — and its cell-map is the identity grid regardless of focus. Such
  cases pin only output *dims* (kept + labelled `dims-pin`). To actually exercise
  focus placement, crop region, and fit, the focus/crop cases use ASYMMETRIC
  consumers (`cover=300x100`, `cover=100x300`, ratio crops) or a small guided
  `crop` (which, like the #321 probe, lands on a single cell and reads the carried
  point). Negative-focus *rejection* (TwicPics 404s; ImagePipe 400s) has no grid to
  decode, so it is out of this structural suite — it lives in the `Units` parser
  unit tests; see the suite README.
  """
  def all do
    [
      # --- focus anchors steer an ASYMMETRIC cover (the cropped axis reveals the point) ---
      c("focus_center_cover_wide", "focus=center/cover=300x100", :focus),
      c("focus_topleft_cover_wide", "focus=top-left/cover=300x100", :focus),
      c("focus_bottomright_cover_wide", "focus=bottom-right/cover=300x100", :focus),
      c("focus_left_cover_tall", "focus=left/cover=100x300", :focus),
      c("focus_right_cover_tall", "focus=right/cover=100x300", :focus),
      # --- focus pixel + relative coords (0-based), asymmetric consumer ---
      c("focus_px_origin_cover_wide", "focus=0x0/cover=300x100", :focus),
      c("focus_px_last_cover_tall", "focus=399x399/cover=100x300", :focus),
      c("focus_rel_mid_cover_wide", "focus=50px50p/cover=300x100", :focus),
      c("focus_mixed_units_cover_tall", "focus=300x50p/cover=100x300", :focus),
      # --- focus OOB clamp (confirmed live: positive past-edge clamps to the edge) ---
      c("focus_oob_clamp_cover_wide", "focus=500x500/cover=300x100", :focus),
      # `150px150p` is 150p × 150p (150% × 150%) — NOT a `px` pixel unit; both clamp to
      # the far edge (confirmed live; the parser clamps ratio>1 per #321).
      c("focus_oob_rel_clamp_cover_tall", "focus=150px150p/cover=100x300", :focus),
      # --- cover-RATIO steered by focus (the documented ratio consumer, #321) ---
      c("focus_topleft_cover_ratio", "focus=top-left/cover=16:9", :focus),
      c("focus_bottomright_cover_ratio", "focus=bottom-right/cover=2:3", :focus),
      # --- focus carry-through: identical focus, resize before vs after → different cell ---
      # resize first (400→200): focus 50x50 in the 200-frame = source (100,100) = cell (1,1)
      c("focus_carry_then_crop", "resize=50p/focus=50x50/crop=40x40", :focus),
      # focus first in the 400-frame: source (50,50) = cell (0,0), carried through resize
      c("focus_carry_resize_then_crop", "focus=50x50/resize=50p/crop=40x40", :focus),
      # --- focus persists across MULTIPLE consumers (asymmetric cover, then crop) ---
      c("focus_multi_consumer", "focus=top-left/cover=300x100/crop=40x40", :focus),
      # --- cover: size (asymmetric = discriminating; square = dims-pin) + ratio ---
      c("cover_wide", "cover=300x100", :cover),
      c("cover_tall", "cover=100x300", :cover),
      c("cover_square_dimspin", "cover=200x200", :cover),
      c("cover_ratio_wide", "cover=16:9", :cover),
      c("cover_ratio_tall", "cover=2:3", :cover),
      # --- contain: fits inside box, may be smaller, no pad (wide/tall discriminate) ---
      c("contain_wide", "contain=300x100", :contain),
      c("contain_tall", "contain=100x300", :contain),
      c("contain_square_dimspin", "contain=150x150", :contain),
      # --- inside: fits + letterbox to the exact box (translucent borders). Square-in-
      # square produces NO letterbox (== contain) so it can't discriminate; only the
      # asymmetric boxes letterbox and are worth baking. ---
      c("inside_wide_lr", "inside=300x100", :inside),
      c("inside_tall_tb", "inside=100x300", :inside),
      # --- crop: guided (focus) vs region@coords (resets focus to crop centre) ---
      c("crop_guided_focus_tl", "focus=top-left/crop=120x120", :crop),
      c("crop_region_origin", "crop=160x160@40x40", :crop),
      # region@coords RESETS focus to the crop centre (source ~(280,280) = cell (2,2)),
      # so the trailing guided crop reads (2,2) despite the earlier focus=0x0…
      c("crop_region_reset", "focus=0x0/crop=160x160@200x200/crop=80x80", :crop),
      # …and this contrast case (same focus=0x0, guided crop, no region reset) must
      # read cell (0,0) — the pair makes the reset observable, not coincidental.
      c("crop_guided_no_reset_contrast", "focus=0x0/crop=80x80", :crop)
    ]
  end

  @default_tol ImagePipe.Test.TwicpicsDifferential.StructureCompare.default_tol()
  @doc "Decode tolerance for a case carrying no explicit `:tol`."
  def default_tol, do: @default_tol

  defp c(id, chain, group, opts \\ []) do
    Map.merge(
      %{id: id, source: :grid_4x4, chain: chain, verdict: :equal, group: group},
      Map.new(opts)
    )
  end
end
```

- [ ] **Step 4: Implement the `Harness` wrapper**

```elixir
# test/support/image_pipe/test/twicpics_differential/harness.ex
defmodule ImagePipe.Test.TwicpicsDifferential.Harness do
  @moduledoc "Thin wrapper over `Differential.Harness` for the TwicPics suite."
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Harness, as: Shared
  alias ImagePipe.Test.TwicpicsDifferential.Constellations

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"

  def plug_opts, do: Shared.plug_opts(ImagePipe.Parser.TwicPics, @sources_dir)

  def render(constellation, plug_opts \\ plug_opts()),
    do: Shared.render(Constellations.twicpics_path(constellation), plug_opts)

  def render_image(constellation, plug_opts \\ plug_opts()),
    do: Shared.render_image(Constellations.twicpics_path(constellation), plug_opts)

  def fixtures_dir, do: @fixtures_dir
  def sources_dir, do: @sources_dir
  def fixture_path(filename), do: Path.join(@fixtures_dir, filename)
end
```

- [ ] **Step 5: Run constellations + inventory tests, verify green**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/constellations_test.exs test/image_pipe/twicpics_source_inventory_test.exs`
Expected: PASS. If any chain fails to parse, that is a real parser gap — mark the case `triage: %{reason: "...", issue: 323}` (it stays in the list, excluded from the parse gate) and note it for the compat reviewer; do not delete it.

- [ ] **Step 6: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/constellations.ex test/support/image_pipe/test/twicpics_differential/harness.ex test/support/image_pipe/test/twicpics_differential/constellations_test.exs
git commit -m "feat(twicpics-diff): full-initial-scope constellations + harness wrapper"
```

### Task 6: `Manifest` (load/validate/write) + conformance test (no fixtures yet)

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/manifest.ex`
- Create: `test/support/image_pipe/test/twicpics_differential/manifest_test.exs`
- Create: `test/image_pipe/twicpics_differential_conformance_test.exs`
- Modify: `test/test_helper.exs`

- [ ] **Step 1: Write the failing Manifest test (round-trip + validate)**

```elixir
# test/support/image_pipe/test/twicpics_differential/manifest_test.exs
defmodule ImagePipe.Test.TwicpicsDifferential.ManifestTest do
  use ExUnit.Case, async: true
  alias ImagePipe.Test.TwicpicsDifferential.Manifest

  @manifest %{
    twicpics_api: "v1",
    baked_at: "2026-06-16T00:00:00Z",
    sources: %{"grid_4x4.png" => %{sha256: String.duplicate("a", 64), hosted_url: "https://h/x.png"}},
    entries: %{
      "cover_square" => %{
        authored_sha256: String.duplicate("b", 64),
        oracle_signature: String.duplicate("c", 64),
        fixture_filename: "cover_square.png",
        fixture_sha256: String.duplicate("d", 64),
        dims: {200, 200},
        bands: 4,
        cells: [{:cell, {0, 0}}, :padding]
      }
    }
  }

  test "write! then load! round-trips and validates" do
    path = Path.join(System.tmp_dir!(), "twic_manifest_#{System.unique_integer([:positive])}.exs")
    Manifest.write!(path, @manifest)
    assert Manifest.load!(path).entries["cover_square"].dims == {200, 200}
  end

  test "load! raises on a malformed entry (whole manifest, so the entry guard fires)" do
    path = Path.join(System.tmp_dir!(), "twic_bad_#{System.unique_integer([:positive])}.exs")
    bad = put_in(@manifest.entries["cover_square"].dims, "nope")
    File.write!(path, inspect(bad, limit: :infinity))
    # Top-level keys are intact, so this reaches validate_entry! and rejects `dims: "nope"`.
    assert_raise RuntimeError, ~r/cover_square/, fn -> Manifest.load!(path) end
  end

  test "oracle_signature depends on chain + suffix + source identity, not tol/verdict" do
    base = %{chain: "cover=200x200", suffix: "output=png/dpr=1", source_sha256: String.duplicate("a", 64)}
    s1 = Manifest.oracle_signature(base)
    s2 = Manifest.oracle_signature(base)
    s3 = Manifest.oracle_signature(%{base | chain: "cover=300x100"})
    assert s1 == s2 and s1 != s3
  end

  describe "fresh?/3 (the incremental-bake staleness predicate)" do
    setup do
      path = Path.join(System.tmp_dir!(), "twic_fx_#{System.unique_integer([:positive])}.png")
      File.write!(path, "pngbytes")
      sha = Manifest.file_sha256(path)
      entry = %{oracle_signature: "sig1", fixture_sha256: sha}
      on_exit(fn -> File.rm(path) end)
      {:ok, path: path, sha: sha, entry: entry}
    end

    test "nil prior is never fresh (new case)", %{path: path} do
      refute Manifest.fresh?(nil, "sig1", path)
    end

    test "matching signature + present + matching hash is fresh", %{path: path, entry: entry} do
      assert Manifest.fresh?(entry, "sig1", path)
    end

    test "changed signature is stale", %{path: path, entry: entry} do
      refute Manifest.fresh?(entry, "sig2", path)
    end

    test "missing fixture file is stale", %{entry: entry} do
      refute Manifest.fresh?(entry, "sig1", "/no/such/fixture.png")
    end

    test "corrupted fixture (hash mismatch) is stale", %{path: path, entry: entry} do
      File.write!(path, "different")
      refute Manifest.fresh?(entry, "sig1", path)
    end
  end
end
```

- [ ] **Step 2: Run test, verify it fails**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/manifest_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement `Manifest`**

```elixir
# test/support/image_pipe/test/twicpics_differential/manifest.ex
defmodule ImagePipe.Test.TwicpicsDifferential.Manifest do
  @moduledoc """
  Generated provenance for the TwicPics differential suite (`manifest.exs`). A
  git-diffable Elixir term; machine-only (REPORT.md is the human record). Data
  crossing a serialization boundary, so `load!/1` validates shape and fails loudly.
  Serialization is delegated to `Differential.ManifestTerm`.
  """
  alias ImagePipe.Test.Differential.ManifestTerm

  # Authored fields whose change requires a reauthor (verdict/tol) — NOT the
  # oracle-affecting inputs (those drive the oracle signature / a re-bake).
  @authored_keys [:source, :chain, :verdict, :group, :tol, :divergence]

  @doc "Authored-field hash of a constellation (order-independent)."
  def authored_sha256(c), do: ManifestTerm.authored_sha256(c, @authored_keys)

  @doc "File-byte hash."
  defdelegate file_sha256(path), to: ManifestTerm

  @doc """
  Hash over the inputs that determine TwicPics' output: chain, pinned suffix, and
  the hosted source's byte identity. Excludes tol/verdict/group.
  """
  def oracle_signature(%{chain: chain, suffix: suffix, source_sha256: src}) do
    :crypto.hash(:sha256, :erlang.term_to_binary({chain, suffix, src}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The incremental-bake staleness predicate: a prior entry is fresh (skip the
  oracle) only when its oracle signature still matches AND its committed PNG is
  present AND that PNG's bytes still match the recorded hash. A `nil` prior (new
  case) is never fresh. Keeps the skip decision pure and testable.
  """
  @spec fresh?(map() | nil, String.t(), Path.t()) :: boolean()
  def fresh?(nil, _sig, _path), do: false

  def fresh?(%{oracle_signature: recorded_sig, fixture_sha256: recorded_hash}, sig, path) do
    recorded_sig == sig and File.exists?(path) and file_sha256(path) == recorded_hash
  end

  @doc "Pretty-print the manifest term to `path` (mix-format stable, key-sorted)."
  def write!(path, %{} = manifest) do
    body =
      "%{" <>
        "twicpics_api: #{inspect(manifest.twicpics_api)}," <>
        "baked_at: #{inspect(manifest.baked_at)}," <>
        "sources: #{ManifestTerm.sorted_map_literal(manifest.sources)}," <>
        "entries: #{ManifestTerm.sorted_map_literal(manifest.entries)}}"

    ManifestTerm.write!(path, body)
  end

  @doc "Load + validate a manifest term."
  def load!(path) do
    {term, _binding} = Code.eval_file(path)
    validate!(term)
  end

  defp validate!(%{twicpics_api: a, baked_at: b, sources: s, entries: e} = m)
       when is_binary(a) and is_binary(b) and is_map(s) and is_map(e) do
    Enum.each(e, fn {id, entry} -> validate_entry!(id, entry) end)
    m
  end

  defp validate!(other),
    do: raise("invalid manifest: missing top-level keys in #{inspect(other, limit: 5)}")

  defp validate_entry!(_id, %{
         authored_sha256: a,
         oracle_signature: o,
         fixture_filename: f,
         fixture_sha256: fs,
         dims: {w, h},
         bands: bands,
         cells: cells
       })
       when is_binary(a) and is_binary(o) and is_binary(f) and is_binary(fs) and
              is_integer(w) and is_integer(h) and is_integer(bands) and is_list(cells),
       do: :ok

  defp validate_entry!(id, entry),
    do: raise("invalid manifest: entry #{inspect(id)} malformed: #{inspect(entry)}")
end
```

- [ ] **Step 4: Run Manifest test, verify it passes**

Run: `mise exec -- mix test test/support/image_pipe/test/twicpics_differential/manifest_test.exs`
Expected: PASS.

- [ ] **Step 5: Write the conformance test (bootstrap-aware) + register excludes**

The default lane has no fixtures until Phase 3. The test must raise a clear bootstrap message when the manifest is absent (mirror imgproxy) — so until the bake runs it is a single clear failure, not many.

```elixir
# test/image_pipe/twicpics_differential_conformance_test.exs
defmodule ImagePipe.TwicpicsDifferentialConformanceTest do
  use ExUnit.Case, async: true

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest, SourceInventory, StructureCompare}

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @manifest_path "#{@base}/manifest.exs"

  setup_all do
    unless File.exists?(@manifest_path) do
      raise "No fixtures: missing #{@manifest_path}. Bootstrap: mise run twic:bake"
    end

    {:ok, manifest: Manifest.load!(@manifest_path)}
  end

  for constellation <- Constellations.all() do
    @c constellation
    if constellation[:triage], do: @tag(:twicpics_triage)

    test "#{@c.id} (#{@c.verdict}/#{@c.group})", %{manifest: manifest} do
      entry = fetch_entry!(manifest, @c.id)

      assert entry.authored_sha256 == Manifest.authored_sha256(@c),
             "#{@c.id}: authored fields changed — run `mix twicpics.reauthor` (tol/verdict) or re-bake."

      pipe = StructureCompare.extract(Harness.render_image(@c), grid_spec(@c), tol(@c))
      expected = expected_record(@c, entry)

      assert StructureCompare.compare(expected, pipe) == :match,
             "#{@c.id}: structural mismatch\n  expected: #{inspect(expected)}\n  got:      #{inspect(pipe)}"
    end
  end

  test "committed sources match the manifest's recorded hashes", %{manifest: manifest} do
    for {filename, %{sha256: recorded}} <- manifest.sources do
      assert Manifest.file_sha256(Path.join(@sources_dir, filename)) == recorded,
             "source #{filename} changed since bake — restore it or re-bake (`mise run twic:bake`)."
    end
  end

  # The reference PNG is non-gating (the structural record is the gate), but the
  # manifest records its hash precisely so corruption/edits are detectable — verify
  # it, matching imgproxy's fixture-hash discipline.
  test "committed reference PNGs match the manifest's recorded hashes", %{manifest: manifest} do
    for {id, %{fixture_filename: f, fixture_sha256: recorded}} <- manifest.entries do
      path = Harness.fixture_path(f)
      assert File.exists?(path), "#{id}: missing reference PNG #{path} — re-bake (`mise run twic:bake`)."

      assert Manifest.file_sha256(path) == recorded,
             "#{id}: reference PNG #{f} sha256 mismatch — corrupted or edited; re-bake."
    end
  end

  defp grid_spec(c), do: SourceInventory.grid(Constellations.source_file(c))
  defp tol(c), do: c[:tol] || Constellations.default_tol()

  # :equal asserts pipe == oracle record; :diverges asserts pipe == recorded
  # ImagePipe-divergent record (oracle differs, by design).
  defp expected_record(%{verdict: :equal}, e), do: %{dims: e.dims, bands: e.bands, cells: e.cells}
  defp expected_record(%{verdict: :diverges}, e), do: e.divergence.pipe

  defp fetch_entry!(manifest, id) do
    case Map.fetch(manifest.entries, id) do
      {:ok, entry} -> entry
      :error -> flunk("#{id}: no manifest entry. Run: mise run twic:bake")
    end
  end
end
```

In `test/test_helper.exs`, add `:twicpics_triage` and `:twicpics_report` to the `exclude:` list (alongside the imgproxy ones).

- [ ] **Step 6: Run, verify the bootstrap failure is the single clear message**

Run: `mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs`
Expected: FAIL — every test errors in `setup_all` with "No fixtures: ... Bootstrap: mise run twic:bake". This is expected pre-bake.

- [ ] **Step 7: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/manifest.ex test/support/image_pipe/test/twicpics_differential/manifest_test.exs test/image_pipe/twicpics_differential_conformance_test.exs test/test_helper.exs
git commit -m "feat(twicpics-diff): manifest module + conformance test (pre-bake bootstrap)"
```

---

## Phase 3 — The bake (network) and first fixtures

### Task 7: `mix twicpics.gen_fixtures` (incremental, catbox, live oracle)

**Files:**
- Create: `test/support/mix/tasks/twicpics.gen_fixtures.ex`
- Modify: `mix.exs` (`preferred_envs`)
- Create: `mise.toml` task `twic:bake`

- [ ] **Step 1: Implement the bake task**

```elixir
# test/support/mix/tasks/twicpics.gen_fixtures.ex
defmodule Mix.Tasks.Twicpics.GenFixtures do
  @shortdoc "Bake TwicPics differential fixtures from the live hosted API (network)"
  @moduledoc """
  Incremental bake against live hosted TwicPics. For each constellation, fetches
  the oracle output ONLY when new / signature-changed / PNG missing-or-corrupt;
  unchanged cases are skipped with zero requests. Uploads any source lacking a
  recorded hosted URL to catbox. Prunes orphaned entries + PNGs. Writes
  `manifest.exs`, reference PNGs, and `REPORT.md`. Requires network; never on the
  default test lane.

      mise run twic:bake                 # incremental
      mix twicpics.gen_fixtures --force  # re-bake all
      mix twicpics.gen_fixtures --only cover_square,inside_wide_lr
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Manifest, SourceInventory, StructureCompare}

  @base "test/support/image_pipe/test/twicpics_differential"
  @sources_dir "#{@base}/sources"
  @fixtures_dir "#{@base}/fixtures"
  @manifest_path "#{@base}/manifest.exs"
  @catbox "https://catbox.moe/user/api.php"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [force: :boolean, only: :string])
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    {:ok, _} = Application.ensure_all_started(:req)
    File.mkdir_p!(@fixtures_dir)

    # Fail fast: a chain that doesn't parse must abort BEFORE any live oracle call
    # (network is the expensive/rate-limited resource here) — imgproxy's pre-bake
    # parse gate, adapted. Triaged cases (known parser gaps) are skipped.
    validate_parses!()

    only = opts[:only] && String.split(opts[:only], ",", trim: true) |> MapSet.new()
    prior = if File.exists?(@manifest_path), do: Manifest.load!(@manifest_path), else: empty_manifest()

    sources = resolve_sources(prior.sources)
    cases = Enum.filter(Constellations.all(), &is_nil(&1[:triage]))

    entries =
      cases
      |> Enum.reduce(%{}, fn c, acc ->
        Map.put(acc, c.id, bake_case(c, sources, prior.entries[c.id], opts[:force], only))
      end)

    prune_orphans!(entries)
    manifest = %{twicpics_api: "v1", baked_at: timestamp(), sources: sources, entries: entries}
    Manifest.write!(@manifest_path, manifest)
    write_report!(manifest)
    Mix.shell().info("Baked #{map_size(entries)} cases (#{@manifest_path}).")
  end

  defp validate_parses!() do
    import Plug.Test, only: [conn: 2]

    failures =
      Constellations.all()
      |> Enum.reject(&(&1[:triage]))
      |> Enum.flat_map(fn c ->
        case ImagePipe.Parser.TwicPics.parse(conn(:get, Constellations.twicpics_path(c)), []) do
          {:ok, _} -> []
          other -> [{c.id, c.chain, other}]
        end
      end)

    if failures != [] do
      detail = Enum.map_join(failures, "\n", fn {id, ch, r} -> "  #{id}: #{ch} → #{inspect(r)}" end)
      Mix.raise("parse gate: #{length(failures)} chain(s) don't parse — fix or triage:\n#{detail}")
    end
  end

  # --- per-case ---
  defp bake_case(c, sources, prior, force, only) do
    src = sources[Constellations.source_file(c)]
    grid = SourceInventory.grid(Constellations.source_file(c))
    sig = Manifest.oracle_signature(%{chain: c.chain, suffix: Constellations.suffix(), source_sha256: src.sha256})
    fixture = "#{c.id}.png"
    path = Path.join(@fixtures_dir, fixture)

    case decide(c, prior, sig, path, force, only) do
      :keep ->
        Mix.shell().info("skip  #{c.id} (unchanged)")
        # prior is non-nil here (decide only returns :keep with a prior entry).
        %{prior | authored_sha256: Manifest.authored_sha256(c)}

      :bake ->
        Mix.shell().info("bake  #{c.id}")
        body = fetch_oracle!(c)
        File.write!(path, body)
        img = decode(body)
        rec = StructureCompare.extract(img, grid)

        case StructureCompare.low_confidence_samples(img, grid) do
          [] -> :ok
          idx -> Mix.shell().info("  ⚠ #{c.id}: low-confidence samples at #{inspect(idx)} — review margin (truecolor?).")
        end

        %{
          authored_sha256: Manifest.authored_sha256(c),
          oracle_signature: sig,
          fixture_filename: fixture,
          fixture_sha256: Manifest.file_sha256(path),
          dims: rec.dims,
          bands: rec.bands,
          cells: rec.cells
        }
    end
  end

  # Pure-ish skip decision (the staleness check itself is Manifest.fresh?/3):
  #   --force            → bake everything
  #   --only, listed     → bake (explicit request)
  #   --only, unlisted   → keep prior if present (no network), else bake (no prior to keep)
  #   no flags, fresh    → keep
  #   no flags, stale    → bake
  defp decide(c, prior, sig, path, force, only) do
    cond do
      force -> :bake
      only && MapSet.member?(only, c.id) -> :bake
      only && not is_nil(prior) -> :keep
      is_nil(only) and Manifest.fresh?(prior, sig, path) -> :keep
      true -> :bake
    end
  end

  defp fetch_oracle!(c) do
    src = SourceInventory.all() |> Enum.find(&(&1.file == Constellations.source_file(c)))
    url = "#{src.hosted_url}?twic=v1/#{c.chain}/#{Constellations.suffix()}"

    case Req.get(url, decode_body: false, retry: :transient, max_retries: 3) do
      {:ok, %{status: 200, body: body}} -> body
      {:ok, %{status: s}} -> Mix.raise("#{c.id}: TwicPics returned #{s} for #{url}")
      {:error, e} -> Mix.raise("#{c.id}: #{Exception.message(e)} for #{url}")
    end
  end

  defp decode(body), do: Image.open!(body, access: :random, fail_on: :error)

  # --- sources: reuse recorded hosted URL + verify remote matches committed bytes;
  # upload to catbox only when no hosted URL is recorded. ---
  defp resolve_sources(_prior) do
    Map.new(SourceInventory.all(), fn entry ->
      path = Path.join(@sources_dir, entry.file)
      committed = Manifest.file_sha256(path)
      hosted_url = entry.hosted_url || upload_catbox!(path, entry)
      verify_remote!(entry, committed)
      {entry.file, %{sha256: committed, hosted_url: hosted_url}}
    end)
  end

  defp verify_remote!(%{source_bytes_url: nil}, _committed), do: :ok

  defp verify_remote!(%{source_bytes_url: url} = entry, committed) do
    case Req.get(url, decode_body: false, retry: :transient) do
      {:ok, %{status: 200, body: body}} ->
        remote = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

        if remote != committed do
          Mix.raise("source #{entry.file}: hosted bytes (#{url}) differ from committed — re-upload or re-download.")
        end

      other ->
        Mix.raise("source #{entry.file}: could not verify hosted bytes (#{inspect(other)}).")
    end
  end

  # Anonymous catbox upload → returns the file URL as plain text.
  defp upload_catbox!(path, entry) do
    form = [reqtype: "fileupload", fileToUpload: {File.read!(path), filename: entry.file, content_type: "image/png"}]

    case Req.post(@catbox, form_multipart: form) do
      {:ok, %{status: 200, body: body}} ->
        id = body |> String.trim() |> Path.basename()
        "https://imagepipe.twic.pics/#{id}"

      other ->
        Mix.raise("catbox upload failed for #{entry.file}: #{inspect(other)}")
    end
  end

  defp prune_orphans!(entries) do
    keep = entries |> Map.values() |> Enum.map(& &1.fixture_filename) |> MapSet.new()

    @fixtures_dir
    |> Path.join("*.png")
    |> Path.wildcard()
    |> Enum.reject(&MapSet.member?(keep, Path.basename(&1)))
    |> Enum.each(fn orphan ->
      Mix.shell().info("prune #{Path.basename(orphan)}")
      File.rm!(orphan)
    end)
  end

  defp empty_manifest, do: %{twicpics_api: "v1", baked_at: nil, sources: %{}, entries: %{}}
  defp write_report!(manifest), do: File.write!("#{@base}/REPORT.md", report_md(manifest))

  defp report_md(m) do
    rows =
      m.entries
      |> Enum.sort_by(fn {id, _} -> id end)
      |> Enum.map_join("\n", fn {id, e} ->
        "| `#{id}` | #{elem(e.dims, 0)}×#{elem(e.dims, 1)} | #{e.bands} | #{cells_glyph(e.cells)} |"
      end)

    "# TwicPics differential — bake report\n\nBaked: #{m.baked_at}\n\n" <>
      "| case | dims | bands | cell-map |\n|---|---|---|---|\n" <> rows <> "\n"
  end

  defp cells_glyph(cells),
    do: Enum.map_join(cells, " ", fn
      {:cell, {c, r}} -> "#{c}#{r}"
      :padding -> "·"
      :ambiguous -> "?"
    end)

  # `new Date()` is unavailable in workflow scripts but fine in a mix task at runtime.
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
```

- [ ] **Step 2: Add `preferred_envs` + the mise task**

In `mix.exs` `preferred_envs` (near the imgproxy entries ~line 69), add:
```elixir
"twicpics.gen_fixtures": :test,
"twicpics.diagnose": :test,
"twicpics.gen_report": :test,
"twicpics.reauthor": :test
```
In `mise.toml`, add:
```toml
[tasks."twic:bake"]
description = "Bake TwicPics differential fixtures from the live hosted API (network)"
env = { MIX_ENV = "test" }
run = ["mix twicpics.gen_fixtures"]
```

- [ ] **Step 3: Verify Req's multipart tuple shape before running**

Before the first bake, confirm the `form_multipart` file-tuple shape against the installed Req version: `mise exec -- mix run -e 'IO.inspect(Req.MODULE_INFO)'` is not needed — instead check `deps/req` docs or run a dry upload of `/tmp/b7g72c.png`. If the `{bytes, filename:, content_type:}` tuple is rejected, switch to `Req.Multipart`/`{:file, path}` per the installed version. (v1 does not upload — the seed has a hosted URL — so this only matters when adding a new source; still confirm the call compiles.)

- [ ] **Step 4: Run the bake (network)**

Run: `mise run twic:bake`
Expected: `bake <id>` for every case, then `Baked N cases`. `manifest.exs`, `fixtures/*.png`, and `REPORT.md` appear. If a case returns non-200, that is a parser/usage finding — capture it for triage.

- [ ] **Step 5: Run the conformance lane against real fixtures**

Run: `mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs`
Expected: PASS for `:equal` cases where ImagePipe matches TwicPics' placement. **Any mismatch is a finding** — diagnose in Task 8 and sort:
- a **decode-tolerance artifact** (an `:ambiguous` or a low-confidence sample, not a *shifted* cell) → widen that case's `tol` decode params (or pin `truecolor` in the suffix) with a one-line rationale, then `mix twicpics.reauthor`. **Never** loosen tol to bury a genuine placement shift — a shifted cell (not `:ambiguous`) is structural and reads ~a whole cell off.
- an **untriaged / not-yet-modelled divergence** → `triage:` + a tracking issue (default for v1; quarantines the case, keeps it in the suite).
- a **deliberately-modelled divergence** → `verdict: :diverges` with a hand-authored `divergence: %{pipe: %{dims, bands, cells}, reason: "..."}` (ImagePipe's intended structure; the bake records the oracle's). **In the same change**, add the matching "Diverges" note to `docs/twicpics_support_matrix.md` (behavioral/pixel axis per `AGENTS.md`), and have the compat reviewer confirm it reflects real live-TwicPics behavior.

- [ ] **Step 6: Commit the baked fixtures + task**

```bash
git add test/support/mix/tasks/twicpics.gen_fixtures.ex mix.exs mise.toml \
  test/support/image_pipe/test/twicpics_differential/manifest.exs \
  test/support/image_pipe/test/twicpics_differential/fixtures \
  test/support/image_pipe/test/twicpics_differential/REPORT.md
git commit -m "feat(twicpics-diff): incremental live-oracle bake task + baked fixtures"
```

### Task 8: `mix twicpics.diagnose` (no network)

**Files:**
- Create: `test/support/mix/tasks/twicpics.diagnose.ex`

- [ ] **Step 1: Implement diagnose**

Render each (or named) case live, extract structure, compare to the committed record, print a one-line PASS/MISMATCH with dims, bands, and the cell diffs.

```elixir
# test/support/mix/tasks/twicpics.diagnose.ex
defmodule Mix.Tasks.Twicpics.Diagnose do
  @shortdoc "Structural diff of ImagePipe vs committed TwicPics records (no network)"
  @moduledoc "mix twicpics.diagnose [case_id ...] — whole suite if no ids given."
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest, SourceInventory, StructureCompare}
  @manifest_path "test/support/image_pipe/test/twicpics_differential/manifest.exs"

  @impl Mix.Task
  def run(args) do
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    plug_opts = Harness.plug_opts()
    want = MapSet.new(args)

    Constellations.all()
    |> Enum.filter(&(is_nil(&1[:triage]) and (Enum.empty?(want) or MapSet.member?(want, &1.id))))
    |> Enum.each(fn c ->
      entry = manifest.entries[c.id]
      pipe = StructureCompare.extract(Harness.render_image(c, plug_opts), SourceInventory.grid(Constellations.source_file(c)), c[:tol] || Constellations.default_tol())
      expected = %{dims: entry.dims, bands: entry.bands, cells: entry.cells}

      verdict =
        case StructureCompare.compare(expected, pipe) do
          :match -> "PASS"
          {:mismatch, d} -> "MISMATCH #{inspect(d)}"
        end

      Mix.shell().info(String.pad_trailing(c.id, 32) <> "#{elem(pipe.dims,0)}×#{elem(pipe.dims,1)} b#{pipe.bands}  #{verdict}")
    end)
  end
end
```

- [ ] **Step 2: Run diagnose, verify it runs**

Run: `mise exec -- mix twicpics.diagnose cover_square`
Expected: one line, `cover_square ... PASS` (or a MISMATCH detail if Task 7 surfaced one).

- [ ] **Step 3: Commit**

```bash
git add test/support/mix/tasks/twicpics.diagnose.ex
git commit -m "feat(twicpics-diff): diagnose task (no-network structural diff)"
```

### Task 9: `mix twicpics.reauthor` (no network)

**Files:**
- Create: `test/support/mix/tasks/twicpics.reauthor.ex`

- [ ] **Step 1: Implement reauthor**

Recompute each entry's `authored_sha256` from the current constellation (for tol/verdict-only edits) without touching fixtures or the oracle. Leave `oracle_signature`/`dims`/`bands`/`cells`/fixture fields intact.

```elixir
# test/support/mix/tasks/twicpics.reauthor.ex
defmodule Mix.Tasks.Twicpics.Reauthor do
  @shortdoc "Refresh authored hashes after tol/verdict-only edits (no network)"
  @moduledoc "mix twicpics.reauthor — recompute authored_sha256 from constellations; no bake."
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Manifest}
  @manifest_path "test/support/image_pipe/test/twicpics_differential/manifest.exs"

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), &{&1.id, &1})

    entries =
      Map.new(manifest.entries, fn {id, entry} ->
        case by_id[id] do
          nil -> Mix.raise("reauthor: entry #{id} has no constellation — re-bake to prune.")
          c -> {id, %{entry | authored_sha256: Manifest.authored_sha256(c)}}
        end
      end)

    Manifest.write!(@manifest_path, %{manifest | entries: entries})
    Mix.shell().info("Reauthored #{map_size(entries)} entries.")
  end
end
```

- [ ] **Step 2: Run reauthor + conformance, verify green**

Run: `mise exec -- mix twicpics.reauthor && mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs`
Expected: "Reauthored N entries"; conformance PASS.

- [ ] **Step 3: Commit**

```bash
git add test/support/mix/tasks/twicpics.reauthor.ex test/support/image_pipe/test/twicpics_differential/manifest.exs
git commit -m "feat(twicpics-diff): reauthor task (tol/verdict-only hash refresh)"
```

---

## Phase 4 — Report (extract shared shell + heatmap; build TwicPics report)

Non-gating; comes after the suite is green.

### Task 10: Extract `Differential.Heatmap`

**Files:**
- Create: `test/support/image_pipe/test/differential/heatmap.ex`
- Modify: `test/support/mix/tasks/imgproxy.gen_report.ex`

- [ ] **Step 1: Move the three heatmap renderers**

Read `imgproxy.gen_report.ex` around the `banded_heatmap/3`, `raw_heatmap/2`, `normalized_heatmap/2`, `png/1`, `data_uri/2` private functions (~lines 185-200+). Move `banded_heatmap`, `raw_heatmap`, `normalized_heatmap`, and `png` into the shared module as public functions; keep `data_uri` in the task (it is generic but trivial). Preserve the exact Vix operations.

```elixir
# test/support/image_pipe/test/differential/heatmap.ex
defmodule ImagePipe.Test.Differential.Heatmap do
  @moduledoc """
  Generic diff-image renderers for differential reports: given two SAME-dimension
  decoded images, produce banded-over-threshold and raw-amplified diff images.
  Informational only — never a gate. (imgproxy keeps its delta/outlier *metric* in
  PixelCompare; only the image-rendering half lives here.)
  """
  use Boundary, top_level?: true, deps: []

  # ... paste banded_heatmap/3, raw_heatmap/2, normalized_heatmap/2, png/1 verbatim
  #     from imgproxy.gen_report.ex, changing `defp` -> `def`. ...
end
```

- [ ] **Step 2: Refactor imgproxy gen_report to delegate**

In `imgproxy.gen_report.ex`: `alias ImagePipe.Test.Differential.Heatmap`; replace the moved private calls with `Heatmap.banded_heatmap(...)`, `Heatmap.raw_heatmap(...)`, `Heatmap.normalized_heatmap(...)`, `Heatmap.png(...)`; delete the moved privates.

- [ ] **Step 3: Run imgproxy report, verify identical output structure**

Run: `mise exec -- mix imgproxy.gen_report --out /tmp/imgproxy_report.html && grep -c "heat-banded" /tmp/imgproxy_report.html`
Expected: report writes; banded panels present (count > 0).

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/test/differential/heatmap.ex test/support/mix/tasks/imgproxy.gen_report.ex
git commit -m "refactor(differential): extract shared Heatmap renderer"
```

### Task 11: Extract `Differential.ReportShell`

**Files:**
- Create: `test/support/image_pipe/test/differential/report_shell.ex`
- Modify: `test/support/image_pipe/test/imgproxy_differential/report_html.ex`

- [ ] **Step 1: Define the shell interface and move chrome**

`ReportShell.page/1` takes `%{title, provenance_html, counts_html, controls_html, cards_html, css, script}` and returns the full HTML document (the skeleton currently in `report_html.ex` `render/1` at lines ~19-45, plus the slider CDN `@slider_css`/`@slider_js` `<link>`/`<script>`). Move the generic skeleton + `esc/1` + the slider constants into the shell; keep imgproxy-specific `css/0`, `script/0`, `card/1`, `visuals/1`, `badges/1`, `counts/1` in `report_html.ex` and pass their output into `page/1`.

```elixir
# test/support/image_pipe/test/differential/report_shell.ex
defmodule ImagePipe.Test.Differential.ReportShell do
  @moduledoc """
  Shared HTML chrome for differential visual-diff reports: document skeleton, the
  img-comparison-slider CDN includes, and HTML-escaping. Each suite supplies its
  own CSS, controls, per-card bodies, and counts; this assembles the page.
  """
  use Boundary, top_level?: true, deps: []

  @slider_css "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/styles.css"
  @slider_js "https://cdn.jsdelivr.net/npm/img-comparison-slider@8/dist/index.js"

  @doc "Assemble the full HTML document from suite-supplied fragments."
  def page(%{title: title, css: css, script: script, header: header, cards: cards} = parts) do
    """
    <!doctype html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>#{esc(title)}</title>
    <link rel="stylesheet" href="#{@slider_css}">
    <script defer src="#{@slider_js}"></script>
    <style>#{css}</style>
    </head>
    <body data-status="all" data-type="all"#{Map.get(parts, :body_attrs, "")}>
    #{header}
    <main>#{cards}</main>
    <script>#{script}</script>
    </body>
    </html>
    """
  end

  @doc "HTML-escape a value."
  def esc(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
  end
end
```

In `report_html.ex`: `alias ImagePipe.Test.Differential.ReportShell`; rewrite `render/1` to build its header/css/script/cards strings as today and return `ReportShell.page(%{title: "imgproxy differential", css: css(), script: script(), header: header(prov, cards), cards: Enum.map_join(cards, "\n", &card/1), body_attrs: ~s| data-heat="banded"|})`. Delegate `esc/1` to `ReportShell.esc/1`. Remove the moved skeleton + slider constants.

- [ ] **Step 2: Run imgproxy report, verify it still renders**

Run: `mise exec -- mix imgproxy.gen_report --out /tmp/r.html && grep -c "img-comparison-slider" /tmp/r.html`
Expected: writes; slider present.

- [ ] **Step 3: Commit**

```bash
git add test/support/image_pipe/test/differential/report_shell.ex test/support/image_pipe/test/imgproxy_differential/report_html.ex
git commit -m "refactor(differential): extract shared ReportShell chrome"
```

### Task 12: TwicPics `ReportHtml` + `mix twicpics.gen_report`

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/report_html.ex`
- Create: `test/support/mix/tasks/twicpics.gen_report.ex`
- Modify: `.gitignore`

- [ ] **Step 1: Implement the TwicPics report builder**

Per case: oracle PNG (committed fixture) vs ImagePipe PNG slider, the decoded cell-map (oracle vs pipe, side by side as small glyph grids or coloured swatches), dims/bands/verdict badges, and — where dims+bands match — the two informational heatmaps via `Differential.Heatmap`, labeled "informational — engine differences expected, not a gate". Use `Differential.ReportShell.page/1` for chrome.

```elixir
# test/support/image_pipe/test/twicpics_differential/report_html.ex
defmodule ImagePipe.Test.TwicpicsDifferential.ReportHtml do
  @moduledoc "Builds the TwicPics differential visual-diff report via the shared ReportShell."
  use Boundary, top_level?: true, deps: []

  alias ImagePipe.Test.Differential.ReportShell

  def render(%{cards: cards} = doc) do
    ReportShell.page(%{
      title: "TwicPics differential",
      css: css(),
      script: "",
      header: header(doc),
      cards: Enum.map_join(cards, "\n", &card/1)
    })
  end

  defp header(%{baked_at: baked_at, cards: cards}) do
    mismatches = Enum.count(cards, &(&1.status == :mismatch))
    ~s|<header><h1>TwicPics differential</h1><p>baked #{ReportShell.esc(baked_at)} · #{length(cards)} cases · #{mismatches} mismatch</p></header>|
  end

  defp card(c) do
    heat =
      if c.heat_banded,
        do: ~s|<figure class="panel"><img src="#{c.heat_banded}"><figcaption>banded diff — informational, not a gate</figcaption></figure>|,
        else: ""

    """
    <section class="card" data-status="#{c.status}">
      <h2>#{ReportShell.esc(c.id)} <small>#{c.verdict}/#{c.group}</small></h2>
      <p>dims #{fmt(c.dims_pipe)} vs #{fmt(c.dims_oracle)} · bands #{c.bands_pipe}/#{c.bands_oracle} · #{c.status}</p>
      <div class="panels">
        <figure class="panel slider"><img-comparison-slider><img slot="first" src="#{c.oracle_png}"><img slot="second" src="#{c.pipe_png}"></img-comparison-slider><figcaption>oracle ↔ ImagePipe</figcaption></figure>
        <figure class="panel"><pre>#{cellmap(c.cells_oracle)}\n#{cellmap(c.cells_pipe)}</pre><figcaption>cell-map oracle / pipe</figcaption></figure>
        #{heat}
      </div>
    </section>
    """
  end

  defp cellmap(cells), do: Enum.map_join(cells, " ", fn {:cell, {x, y}} -> "#{x}#{y}"; :padding -> "·"; :ambiguous -> "?" end)
  defp fmt(nil), do: "—"
  defp fmt({w, h}), do: "#{w}×#{h}"
  defp css, do: ".card{margin:16px 0;border:1px solid #ccc;padding:8px}.panels{display:flex;flex-wrap:wrap;gap:12px}.panel img,.panel img-comparison-slider{max-width:240px}"
end
```

- [ ] **Step 2: Implement the gen_report task**

```elixir
# test/support/mix/tasks/twicpics.gen_report.ex
defmodule Mix.Tasks.Twicpics.GenReport do
  @shortdoc "Self-contained TwicPics differential visual-diff report (no network)"
  @moduledoc "mix twicpics.gen_report [--out report.html] — renders ImagePipe live, reads committed fixtures."
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.Heatmap
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest, SourceInventory, StructureCompare}

  @base "test/support/image_pipe/test/twicpics_differential"
  @manifest_path "#{@base}/manifest.exs"

  @impl Mix.Task
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [out: :string])
    {:ok, _} = Application.ensure_all_started(:image_pipe)
    out = opts[:out] || "#{@base}/report.html"
    manifest = Manifest.load!(@manifest_path)
    plug_opts = Harness.plug_opts()

    cards = Enum.map(Enum.reject(Constellations.all(), &(&1[:triage])), &build_card(&1, manifest, plug_opts))
    File.write!(out, ImagePipe.Test.TwicpicsDifferential.ReportHtml.render(%{baked_at: manifest.baked_at, cards: cards}))
    Mix.shell().info("Wrote #{length(cards)} cards to #{Path.expand(out)}")
  end

  defp build_card(c, manifest, plug_opts) do
    entry = manifest.entries[c.id]
    {body, _ct} = Harness.render(c, plug_opts)
    pipe_img = Image.open!(body, access: :random, fail_on: :error)
    pipe = StructureCompare.extract(pipe_img, SourceInventory.grid(Constellations.source_file(c)), c[:tol] || Constellations.default_tol())
    oracle_bytes = File.read!(Harness.fixture_path(entry.fixture_filename))
    expected = %{dims: entry.dims, bands: entry.bands, cells: entry.cells}
    status = if StructureCompare.compare(expected, pipe) == :match, do: :match, else: :mismatch

    {heat_banded} =
      if pipe.dims == entry.dims and pipe.bands == entry.bands do
        oracle_img = Image.open!(oracle_bytes, access: :random, fail_on: :error)
        {data_uri(Heatmap.png(Heatmap.banded_heatmap(oracle_img, pipe_img, 2)))}
      else
        {nil}
      end

    %{
      id: c.id, verdict: c.verdict, group: c.group, status: status,
      dims_pipe: pipe.dims, dims_oracle: entry.dims, bands_pipe: pipe.bands, bands_oracle: entry.bands,
      cells_pipe: pipe.cells, cells_oracle: entry.cells,
      oracle_png: data_uri(oracle_bytes), pipe_png: data_uri(body), heat_banded: heat_banded
    }
  end

  defp data_uri(bytes), do: "data:image/png;base64,#{Base.encode64(bytes)}"
end
```

- [ ] **Step 3: gitignore the report + run it**

Add to `.gitignore`: `test/support/image_pipe/test/twicpics_differential/report.html`.
Run: `mise exec -- mix twicpics.gen_report --out /tmp/twic_report.html && grep -c "img-comparison-slider" /tmp/twic_report.html`
Expected: writes; slider present.

- [ ] **Step 4: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/report_html.ex test/support/mix/tasks/twicpics.gen_report.ex .gitignore
git commit -m "feat(twicpics-diff): visual-diff report (cell-map + informational heatmap)"
```

---

## Phase 5 — Docs, boundaries, and the full gate

### Task 13: Suite README + support-matrix note

**Files:**
- Create: `test/support/image_pipe/test/twicpics_differential/README.md`
- Modify: `docs/twicpics_support_matrix.md`

- [ ] **Step 1: Write the suite README**

Mirror the imgproxy differential README's sections, adapted: the bake→diagnose→tolerance→quarantine workflow; the mix-task table (`mise run twic:bake`, `mix twicpics.diagnose`, `mix twicpics.gen_report`, `mix twicpics.reauthor`); and the TwicPics-specific notes — **structural not pixel** (assert dims+bands+cell-map; generous colour tolerance only in the decode), the **catbox source-hosting handshake** (committed bytes must equal hosted bytes; the bake verifies), **incremental bake** (oracle signature = `{chain, suffix, source-byte identity}`; `--force`/`--only`; pruning removes a deleted constellation's PNG), and **no libvips provenance** (the cell-map gate is resampler-independent). Also state explicitly:
- **`reauthor` does NOT prune** — only the bake prunes orphaned entries/PNGs. After deleting a constellation, re-bake (it raises in reauthor with that guidance).
- **Negative-focus rejection is out of this suite's scope** — TwicPics 404s and ImagePipe 400s, so there is no grid to decode; that contract is covered by the `Units` parser unit tests.
- **SourceInventory drift** decode-checks dims/bands/format/interpretation (imgproxy parity).
- Pixel heatmaps in the report are **informational only**, never a gate.

- [ ] **Step 2: Add the support-matrix note**

In `docs/twicpics_support_matrix.md`, add a short subsection pointing to the standing differential suite (analogous to how the imgproxy matrix references its differential lane), noting it asserts geometry/placement against live TwicPics and that divergences it surfaces are recorded there.

- [ ] **Step 3: Commit**

```bash
git add test/support/image_pipe/test/twicpics_differential/README.md docs/twicpics_support_matrix.md
git commit -m "docs(twicpics): differential suite README + support-matrix note"
```

### Task 14: Boundary/architecture check + full gate

**Files:**
- Modify (if needed): boundary deps in any module flagged by `mix compile`.

- [ ] **Step 1: Confirm boundaries compile**

Run: `mise exec -- mix compile --warnings-as-errors`
Expected: clean. If `Boundary` flags a cross-namespace call (e.g. a shared `Differential.*` module reaching a suite module), fix the `deps:`/`top_level?:` declaration — shared modules must not depend on suite modules; suites depend on shared.

- [ ] **Step 2: Run the precommit gate**

Run: `mise run precommit`
Expected: format clean, compile clean, credo clean, **all tests pass** (imgproxy suite still green from the refactors; TwicPics conformance green; both inventory drift tests green). The `:twicpics_triage`/`:twicpics_report` tags stay excluded by default.

- [ ] **Step 3: Run the quarantined lane (if any triaged cases exist)**

Run: `MIX_ENV=test mise exec -- mix test test/image_pipe/twicpics_differential_conformance_test.exs --include twicpics_triage`
Expected: triaged cases run (and may fail — that is the tracked gap); untriaged stay green.

- [ ] **Step 4: Commit any boundary fixes**

```bash
git add -A
git commit -m "chore(twicpics-diff): boundary declarations + full gate green"
```

---

## Self-review notes (addressed)

- **Spec coverage:** core model (Task 3,6), hybrid record+PNG (Task 6,7), incremental bake/oracle signature (Task 7), catbox handshake + remote verify (Task 7), shared extraction ManifestTerm/Harness/Heatmap/ReportShell (Tasks 1,2,10,11), full initial scope constellations (Task 5), source inventory drift (Task 4), conformance + triage + source-hash (Task 6), diagnose/reauthor (Tasks 8,9), report with informational heatmap (Task 12), no-libvips-provenance (reflected by absence; noted in README Task 13), docs (Task 13), boundaries (Task 14).
- **Open verification during impl (flagged in-task):** the exact `ImagePipe.Parser.TwicPics` parse entry arity (Task 5 Step 1 — reviewed as `(%Plug.Conn{}, opts)`), Req's `form_multipart` file-tuple shape (Task 7 Step 3), and the seed grid's `format`/`interpretation` facts (Task 4 — drift test asserts them).
- **Compat reviewer:** per `AGENTS.md`, the plan-review cycle must include a TwicPics-compatibility reviewer confirming baked records + any `:diverges` reflect real live-TwicPics behavior. In particular, at bake time confirm the recorded cell-maps for the ratio cases (`cover_ratio_*`, `focus_*_cover_ratio`) are a centre/corner band as expected, not an unexpected alignment.

## Applied review feedback (parallel cycle, 2026-06-16)

Four disjoint-lens reviewers (TwicPics-compat, architecture/boundary, test/correctness, differential-discipline). Accepted and applied:
- **Incremental skip was inverted** for the default no-`--only` path → extracted `Manifest.fresh?/3` (unit-tested) + a clean `decide/6` cond (Task 6, 7).
- **`parse/1` helper returned garbage** → collapsed to the real `parse/2` arity (Task 5).
- **`cell_at` hardcoded 4 cols** → record carries `cols`; index by it (Task 3).
- **Constellation set under-tested behaviors** → asymmetric/discriminating consumers, cover-*ratio* focus steering, the carry-order crop pair, the reset-contrast pair, square cases relabelled `dims-pin`, square `inside` dropped (Task 5).
- **No pre-bake parse gate** → added `validate_parses!/0` aborting before any oracle call (Task 7).
- **`fixture_sha256` recorded but unverified** → added a per-fixture hash test (Task 6).
- **Malformed-manifest test fired the wrong clause** → write the whole manifest so the entry guard fires (Task 6).
- **SourceInventory drift omitted format/interpretation** → added both to the entry + drift test (Task 4).
- **`:diverges` must update the support matrix same-change** → instruction added (Task 7 Step 5).
- **Negative-focus rejection** scoped to parser unit tests + documented (Task 5 moduledoc, Task 13).
- **Low-confidence margin guard** → `StructureCompare.low_confidence_samples/3` + bake warning (Task 3, 7).
- **Manifest stays unbounded** (ingress into `deps: []` boundaries is allowed) — boundary note so the implementer doesn't over-annotate (Task 1, 6).
- **reauthor doesn't prune** — documented (Task 13).
