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
      # Decoded facts (drift test asserts them): 400×400 RGBA, UCHAR/sRGB, no profile.
      format: :VIPS_FORMAT_UCHAR,
      interpretation: :VIPS_INTERPRETATION_sRGB,
      profile?: false,
      grid: @grid_4x4,
      produced_by:
        "Colour grid from the #321 focus probe (tools/make_grid.exs), uploaded to catbox.",
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
