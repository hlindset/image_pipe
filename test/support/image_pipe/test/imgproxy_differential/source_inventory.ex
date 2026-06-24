defmodule ImagePipe.Test.ImgproxyDifferential.SourceInventory do
  @moduledoc """
  Single source of truth for the committed differential test images
  (`sources/`). Each entry records a source's verifiable facts (dims, bands,
  format, interpretation, embedded-profile presence) plus how it is produced, who
  consumes it, and what invariant it must preserve.

  **The verifiable facts are drift-checked** by
  `test/image_pipe/imgproxy_source_inventory_test.exs`, which decodes every file
  and fails if the inventory and the bytes disagree, if a source is added/removed
  without an entry, or if a constellation references an uninventoried source.

  ## Keep this in sync

  Adding, removing, or regenerating a source REQUIRES updating its entry here — the
  drift test fails otherwise. A regeneration that changes any recorded fact (a
  libvips bump, a content change) is a deliberate act: update the entry, re-bake
  (`mise run diff:bake`), and review the consumers below. See the differential
  README's "Source inventory" section.

  `produced_by`:
    * `:gen_sources` — emitted by `mix imgproxy.gen_sources` (the only way to
      regenerate it; running the task overwrites EVERY such file, so `git status
      sources/` afterward and confirm only the intended files changed).

  `consumers` beyond the differential conformance suite (these are the
  cross-couplings that make a source change ripple outside the bake — e.g. the
  color-management tests depend on a source carrying an embedded ICC profile):
    * `:icm` — `test/image_pipe/transform/input_color_management_test.exs`
    * `:icm_sequential` —
      `test/image_pipe/transform/input_color_management_sequential_test.exs`
    * `:color_result` — `test/image_pipe/output/color_result_test.exs`
    * `:wire` — `test/image_pipe/imgproxy_wire_conformance_test.exs`
  Every source is also consumed by the differential suite via `Constellations`.
  """
  use Boundary, top_level?: true, deps: []

  @type entry :: %{
          file: String.t(),
          width: pos_integer(),
          height: pos_integer(),
          bands: pos_integer(),
          format: atom(),
          interpretation: atom(),
          profile?: boolean(),
          produced_by: :gen_sources,
          content: String.t(),
          consumers: [atom()],
          invariant: String.t()
        }

  @entries [
             %{
               file: "marker.png",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Flat dark-gray [30,30,30] field with one red [240,40,40] rect in the top-left eighth. " <>
                   "A single sharp high-contrast edge for resample-skew detection; deliberately uniform elsewhere.",
               consumers: [],
               invariant:
                 "Shared by ~20 constellations whose tols lean on its exact layout. Its uniform field gives " <>
                   "no-resize inline crops zero discriminating power — those migrated to placement.png (#239)."
             },
             %{
               file: "placement.png",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Aperiodic 50px color grid; each cell a distinct xorshift-hashed color (range 40..239). " <>
                   "Sharp high-amplitude edges everywhere + unique per-cell colors encode position.",
               consumers: [],
               invariant:
                 "Aperiodicity is the point (a 1px crop misplacement → maxΔ≈255, and a period-aligned shift " <>
                   "cannot alias). Keep the step < the smallest crop dimension (#239)."
             },
             %{
               file: "placement_odd.png",
               width: 405,
               height: 305,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Aperiodic 5px color grid (xorshift-hashed cells, range 40..239) on ODD 405×305 dims — " <>
                   "the placement.png recipe at a smaller step and odd size.",
               consumers: [],
               invariant:
                 "Both dims odd so `c:0.5:0.5` hits a `.5` crop-SIZE tie (202.5/152.5): imgproxy rounds " <>
                   "half-away (203×153), ties-to-even gives 202×152 (#318). Keep dims odd and step (5) < the " <>
                   "crop window so a stray placement also shows."
             },
             %{
               file: "border.png",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "White field with a centered blue [20,30,200] rect inset 120/90px — a uniform border.",
               consumers: [],
               invariant: "Uniform border is the trim signal; the interior is intentionally flat."
             },
             %{
               file: "border_asym.png",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "White field with an OFF-center blue [20,30,200] rect (margins left=100/right=200, " <>
                   "top=60/bot=140) — an asymmetric border.",
               consumers: [],
               invariant:
                 "Asymmetric opposite margins are the trim `equal_hor`/`equal_ver` symmetrization signal: " <>
                   "plain trim → tight 1300×1000 bbox, `t::1:1` → 1400×1080 reaching into the white border. " <>
                   "On the centered `border.png` the branch is a no-op (diff==0), so do NOT center this rect."
             },
             %{
               file: "high_freq.jpg",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Deterministic radial chirp (zone plate) — broadband high-frequency content.",
               consumers: [:ssim2, :butteraugli],
               invariant:
                 "Heavy-downscale resample-skew source; its diffuse skew calibrates the zone-plate tols. Also the quality-sensitive fixture for the SSIMULACRA2 metric + encode-search unit tests (incl. the native-JXL butteraugli max_bytes self-cap test)."
             },
             %{
               file: "high_freq.webp",
               width: 1600,
               height: 1200,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "The radial chirp re-encoded as WebP — a WebP-decode input twin of high_freq.jpg.",
               consumers: [],
               invariant: "Same chirp as high_freq.jpg; exercises the WebP source-decode path."
             },
             %{
               file: "alpha.png",
               width: 256,
               height: 256,
               bands: 4,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content: "Uniform semi-transparent [0,200,100,128] RGBA fill.",
               consumers: [],
               invariant:
                 "Carries an alpha band for the alpha/background/flatten cases; spatially uniform by design."
             },
             %{
               file: "small.png",
               width: 120,
               height: 90,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Blue [70,130,180] field with a yellow [255,220,0] rect — a small (no-enlarge) source.",
               consumers: [:icm, :color_result],
               invariant:
                 "Untagged sRGB: the ICM `@plain_srgb_fixture` asserts it is a no-op import (no profile). " <>
                   "Keep it profile-less and small enough that fit/enlarge boundaries are reachable."
             },
             %{
               file: "icc_p3.png",
               width: 512,
               height: 512,
               bands: 3,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_sRGB,
               profile?: true,
               produced_by: :gen_sources,
               content:
                 "Red field, white corner, green/blue cross-lines, converted to Display-P3 (embedded P3 profile).",
               consumers: [:icm, :icm_sequential, :color_result],
               invariant:
                 "MUST keep the embedded P3 profile: the ICM `@p3_fixture` asserts a wide-gamut import, and " <>
                   "other tests borrow this profile to tag images in-test."
             },
             %{
               file: "cmyk.jpg",
               width: 120,
               height: 90,
               bands: 4,
               format: :VIPS_FORMAT_UCHAR,
               interpretation: :VIPS_INTERPRETATION_CMYK,
               profile?: true,
               produced_by: :gen_sources,
               content: "An sRGB pattern converted to CMYK (embedded CMYK profile).",
               consumers: [:icm, :icm_sequential],
               invariant:
                 "MUST stay CMYK with its embedded profile: cmyk_import pins the stage-4 CMYK→sRGB import and " <>
                   "the ICM `@cmyk_fixture` asserts color_imported?."
             },
             %{
               file: "rgb16.png",
               width: 512,
               height: 512,
               bands: 3,
               format: :VIPS_FORMAT_USHORT,
               interpretation: :VIPS_INTERPRETATION_RGB16,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "Full 16-bit-range HDR: red field, white corner (65535), green/blue cross-lines, a saturated " <>
                   "highlight block — content reaches the high bits (#240).",
               consumers: [:icm_sequential, :wire],
               invariant:
                 "MUST span the full 16-bit range (do not regress to bottom-8-bit values), so ph:1 preserve " <>
                   "vs ph:0 tonemap is genuinely exercised."
             },
             %{
               file: "rgba16.png",
               width: 512,
               height: 512,
               bands: 4,
               format: :VIPS_FORMAT_USHORT,
               interpretation: :VIPS_INTERPRETATION_RGB16,
               profile?: false,
               produced_by: :gen_sources,
               content:
                 "rgb16's full-range content plus a uniformly fully-opaque (65535) 16-bit alpha band.",
               consumers: [:icm, :icm_sequential],
               invariant:
                 "Alpha MUST stay uniformly opaque (65535) — the #229 rgba16_preserve_hdr divergence depends on " <>
                   "it. Profile-less: the ICM `@rgba16_fixture` test attaches a profile in-test (#240)."
             }
           ] ++
             Enum.map([2, 3, 4, 5, 6, 7, 8], fn o ->
               %{
                 file: "exif_#{o}.jpg",
                 width: 400,
                 height: 300,
                 bands: 3,
                 format: :VIPS_FORMAT_UCHAR,
                 interpretation: :VIPS_INTERPRETATION_sRGB,
                 profile?: false,
                 produced_by: :gen_sources,
                 content:
                   "The 400×300 corner-block base (blue [40,40,200] top-left quadrant on gold [200,180,60]) " <>
                     "retagged with EXIF Orientation #{o}.",
                 consumers: [],
                 invariant:
                   "The blue/gold quadrant layout is load-bearing for the #182 frame-of-reference fixtures " <>
                     "(e.g. smart trim's getpoint(0,0) is frame-sensitive). Do NOT change the base."
               }
             end) ++
             Enum.map([2, 3, 4, 5, 6, 7, 8], fn o ->
               %{
                 file: "exif_placement_#{o}.jpg",
                 width: 400,
                 height: 300,
                 bands: 3,
                 format: :VIPS_FORMAT_UCHAR,
                 interpretation: :VIPS_INTERPRETATION_sRGB,
                 profile?: false,
                 produced_by: :gen_sources,
                 content:
                   "The 400×300 aperiodic 50px placement grid (each cell a distinct xorshift-hashed color, " <>
                     "range 40..239) retagged with EXIF Orientation #{o}.",
                 consumers: [],
                 invariant:
                   "Discriminating EXIF inline-crop source (#239 EXIF half): the `crop_no` seam + " <>
                     "`exif_crop_focal` route here so a placement/fp-rotation bug is maxΔ≈255, not identical " <>
                     "pixels in exif_base's uniform gold ground. Keep the per-cell-unique aperiodicity; step 50 " <>
                     "< the smallest EXIF crop dim (120)."
               }
             end)

  @doc "All inventory entries (one per committed source file)."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "Just the committed source filenames."
  @spec files() :: [String.t()]
  def files, do: Enum.map(@entries, & &1.file)
end
