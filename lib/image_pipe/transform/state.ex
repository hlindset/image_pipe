defmodule ImagePipe.Transform.State do
  @moduledoc """
  Execution state carried through a transform chain.

  Holds the current image, debug flag, and runtime configuration. Operations
  return updated state and access host collaborators without depending on request
  modules:

  - `detector`: host-configured content detector module, or `nil` when no
    detector is configured.
  - `telemetry_opts`: telemetry metadata threaded through stage spans.
  - `materialized?`: the graph has RAM-backed input and can be read out of row
    order without revisiting the sequential source. Later operations may remain
    lazy; this does not imply the current result is a contiguous pixel buffer.
  - `source_dimensions`: exact full-resolution `{w, h}` before shrink-on-load,
    or `nil` for a full-resolution decode. Residual resize uses this extent to
    match the full-resolution target. Pending orientation maps its axes to the
    display frame; a physical quarter-turn flush swaps the extent and shrink
    axes. Resize consumes the extent. Crop, trim, arbitrary rotation, canvas,
    and padding establish new geometry; the executor clears the extent and
    decode scale at those boundaries.
  - `decode_shrink`: realized per-axis factors `%{w: float, h: float}`
    (original ÷ decoded, each `>= 1.0`), or `nil` for a full-resolution decode.
    Crops before resize rescale absolute dimensions and gravity offsets to
    select the same source region; relative coordinates stay unchanged. Integer
    decode dimensions can yield different factors per axis. Factors follow the
    current image axes: gravity crops swap them for a pending quarter turn, then
    map crop dimensions back to the image frame.
  - `source_color_profile` and `color_imported?`: input-color-management results
    passed to the encoder. The profile holds raw source ICC bytes or `nil`; the
    flag records whether `icc_import` ran. Never emit these in telemetry metadata.
  """

  defstruct image: nil,
            debug: false,
            detector: nil,
            telemetry_opts: [],
            source_dimensions: nil,
            decode_shrink: nil,
            pending_orientation: nil,
            materialized?: false,
            source_color_profile: nil,
            color_imported?: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | nil,
          telemetry_opts: keyword(),
          source_dimensions: {pos_integer(), pos_integer()} | nil,
          decode_shrink: %{w: float(), h: float()} | nil,
          pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil,
          materialized?: boolean(),
          source_color_profile: binary() | nil,
          color_imported?: boolean()
        }

  def set_image(%__MODULE__{} = state, %Vix.Vips.Image{} = image) do
    %__MODULE__{state | image: image}
  end

  @doc """
  Returns the dimensions used to calculate the residual resize target.

  Uses the exact stored `source_dimensions` after shrink-on-load, otherwise the
  current image dimensions. After a crop clears the stored extent, resize uses
  the cropped dimensions.
  """
  def effective_source_dims(%__MODULE__{source_dimensions: {w, h}}), do: {w, h}

  def effective_source_dims(%__MODULE__{image: image}),
    do: {Image.width(image), Image.height(image)}
end
