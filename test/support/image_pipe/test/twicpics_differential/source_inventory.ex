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

  @entries [
    %{
      file: "grid_4x4.png",
      hosted_url: "https://imagepipe.twic.pics/b7g72c.png",
      source_bytes_url: "https://files.catbox.moe/b7g72c.png",
      width: 400,
      height: 400,
      bands: 4,
      # Decoded facts (drift test asserts them): 400×400 RGBA, UCHAR/sRGB, no profile.
      format: :VIPS_FORMAT_UCHAR,
      interpretation: :VIPS_INTERPRETATION_sRGB,
      profile?: false,
      produced_by:
        "Colour grid from the #321 focus probe (tools/make_grid.exs), uploaded to catbox.",
      consumers: [:twicpics_differential],
      invariant:
        "400×400 RGBA, 4×4 grid of 100px cells; cell (col,row) = [chan(col,4),chan(row,4),255]. " <>
          "Opaque cells; alpha marks inside-letterbox padding."
    },
    %{
      file: "gradient_large.webp",
      hosted_url: "https://imagepipe.twic.pics/tdkxst.webp",
      source_bytes_url: "https://files.catbox.moe/tdkxst.webp",
      width: 600,
      height: 600,
      bands: 3,
      # Decoded facts (drift test asserts them): 600×600 RGB, UCHAR/sRGB, no profile.
      format: :VIPS_FORMAT_UCHAR,
      interpretation: :VIPS_INTERPRETATION_sRGB,
      profile?: false,
      produced_by:
        "600×600 smooth 2D position gradient (R=round(x·255/599), G=round(y·255/599), B=128), " <>
          "lossless WebP, uploaded to catbox.",
      consumers: [:twicpics_differential],
      invariant:
        "600×600 RGB smooth gradient; each pixel encodes its position (R∝x, G∝y). Large enough " <>
          "that a px cover=300x100 target triggers a clean 2× WebP shrink-on-load (decode_shrink), " <>
          "so an inside=<ratio> Canvas runs with shrink outstanding — the canvas-under-shrink pin. " <>
          "Smooth (not a sharp grid) so shrink-on-load skew vs TwicPics stays sub-tolerance while the " <>
          "gradient still reveals a placement shift."
    }
  ]

  @doc "All inventory entries."
  def all, do: @entries
end
