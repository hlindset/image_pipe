defmodule Mix.Tasks.Twicpics.Diagnose do
  @shortdoc "Triage table (dims/bands/maxΔ/histogram) for TwicPics constellations — no network"
  @moduledoc """
  Renders the named constellations live and prints a one-line triage summary for
  each against the committed TwicPics (libvips) fixture: output dims, band layout,
  the maximum band-byte delta, a band-byte count over Δ2/Δ16/Δ32, and PASS/over-
  budget against the constellation's authored tolerance. No network — fixtures are
  committed and the render is live (the same `Harness` the conformance test uses).

  `maxΔ` is the skew-vs-structural signal: a diffuse libvips-version resampling seam
  stays low (tens), while a placement/crop shift misaligns high-contrast edges
  toward ~255. A band/dim mismatch can't be pixel-compared and is flagged FINDING.

  Each transform line also reports `contrast=N` — the fixture's largest per-band
  **spatial** range (`PixelCompare.spatial_contrast/1`, in 0..255 levels). A
  near-zero value means the fixture is spatially flat, so a placement/crop error
  would move the window within a uniform field and produce identical pixels.

      # specific constellations
      mise exec -- mix twicpics.diagnose focus_topleft_cover_wide cover_ratio_tall

      # the whole suite (INCLUDES quarantined/triaged cases — those are what you
      # want to inspect)
      mise exec -- mix twicpics.diagnose

      # only cases needing attention (over budget / FINDING)
      mise exec -- mix twicpics.diagnose --failing

  Auto-selects `MIX_ENV=test` via `mix.exs` `preferred_envs`.
  """
  use Mix.Task
  use Boundary, top_level?: true, check: [out: false]

  alias ImagePipe.Test.Differential.PixelCompare
  alias ImagePipe.Test.TwicpicsDifferential.{Constellations, Harness, Manifest}

  @manifest_path "test/support/image_pipe/test/twicpics_differential/manifest.exs"
  @thresholds [2, 16, 32]

  # Below this per-band spatial range (0..255 levels) the fixture is treated as
  # spatially flat — a placement/crop shift would be invisible against it.
  @min_contrast 8.0

  @impl Mix.Task
  def run(args) do
    {opts, ids, _} = OptionParser.parse(args, strict: [failing: :boolean])
    failing_only? = Keyword.get(opts, :failing, false)

    {:ok, _} = Application.ensure_all_started(:image_pipe)
    manifest = Manifest.load!(@manifest_path)
    by_id = Map.new(Constellations.all(), &{&1.id, &1})
    plug_opts = Harness.plug_opts()

    selected =
      case ids do
        [] -> Enum.map(Constellations.all(), & &1.id)
        chosen -> chosen
      end

    Enum.each(selected, fn id ->
      {attention?, line} =
        case Map.fetch(by_id, id) do
          {:ok, c} -> diagnose_line(c, manifest, plug_opts)
          :error -> {true, "#{pad(id)}unknown constellation id"}
        end

      if not failing_only? or attention?, do: Mix.shell().info(line)
    end)
  end

  # Returns `{attention?, line}` — attention? marks a case worth eyeballing
  # (over budget, a band/dim FINDING, or an unknown id). `--failing` prints only
  # those.
  defp diagnose_line(c, manifest, plug_opts) do
    entry = Map.fetch!(manifest.entries, c.id)
    out = Harness.render_image(c, plug_opts)
    fixture = Harness.fixture_image(entry)
    tol = c[:tol] || Constellations.default_tol()
    d = PixelCompare.diagnose(out, fixture, Enum.uniq([tol.threshold | @thresholds]))
    contrast = PixelCompare.spatial_contrast(fixture)
    flat? = contrast < @min_contrast
    attention? = not d.comparable or Map.fetch!(d.over, tol.threshold) > tol.budget
    structural = if d.comparable, do: PixelCompare.structural_outliers(out, fixture)

    {attention?, pad(c.id) <> body_for(d, tol, structural) <> contrast_suffix(contrast, flat?)}
  end

  defp body_for(%{comparable: false} = d, _tol, _structural) do
    {{wa, ha}, {wb, hb}} = d.dims
    {ba, bb} = d.bands
    dims = if {wa, ha} == {wb, hb}, do: "#{wa}×#{ha}", else: "#{wa}×#{ha}≠#{wb}×#{hb}"
    "FINDING — bands #{ba}/#{bb}, dims #{dims} (not pixel-comparable)"
  end

  defp body_for(%{comparable: true} = d, tol, structural) do
    {{w, h}, _} = d.dims
    {ba, _} = d.bands
    over = d.over
    hist = Enum.map_join(@thresholds, " ", fn t -> ">Δ#{t}=#{Map.fetch!(over, t)}" end)
    pass? = Map.fetch!(over, tol.threshold) <= tol.budget

    "dims #{w}×#{h}  bands #{ba}  maxΔ=#{d.max_delta}  #{hist}  " <>
      "tol Δ#{tol.threshold}/#{tol.budget} → #{if pass?, do: "PASS", else: "OVER BUDGET"}  " <>
      structural_suffix(structural, Map.fetch!(over, 2))
  end

  # The neighborhood-aware triage signal (`PixelCompare.structural_outliers/3`, radius
  # 1): differing samples NOT explainable by the reference's local range. A small
  # minority of the Δ2 diff means resampling/phase skew (sub-pixel); a majority means a
  # real geometry shift. Informational — never gated.
  defp structural_suffix(structural, over2) do
    label =
      cond do
        over2 == 0 -> "—"
        structural * 2 >= over2 -> "geometry shift"
        true -> "resampling/phase"
      end

    "structural=#{structural} (r1) → #{label}"
  end

  defp contrast_suffix(contrast, flat?) do
    base = "  contrast=#{:erlang.float_to_binary(contrast, decimals: 1)}"
    if flat?, do: base <> " ⚠ near-uniform (placement non-discriminating)", else: base
  end

  defp pad(id), do: String.pad_trailing(id, 34)
end
