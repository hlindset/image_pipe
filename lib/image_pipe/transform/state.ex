defmodule ImagePipe.Transform.State do
  @moduledoc """
  Execution state carried through a transform chain.

  State holds the current image and debug flag used by product-neutral
  operations. Operations return an updated state instead of mutating images in
  place.

  Injected runtime configuration also rides on the state so operations can reach
  host-provided collaborators without naming concrete request modules:

  - `detector`: host-configured content detector, either a bare `module` or a
    `{module, opts}` pair, or `nil` when no detector is configured.
  - `detector_required`: whether detect-gravity must use the detector instead of
    silently falling back to attention smartcrop.
  - `telemetry_opts`: telemetry metadata threaded through stage spans.
  - `source_dimensions`: the *exact* original (full-resolution) `{w, h}` the
    residual resize must size against, set by decode when shrink-on-load has reduced
    the decoded image; `nil` otherwise. It is exact (not reconstructed from the shrunk
    dims), so the residual resize lands on the same target as a full-resolution
    decode. Pending orientation describes how those axes map to the display
    frame. A physical quarter-turn flush swaps the surviving extent and shrink
    axes. A resize consumes the source extent; crop, trim, arbitrary rotation,
    canvas, and padding establish geometry from their resulting image. The
    executor clears the source extent and decode scale at those boundaries.
  - `decode_shrink`: the *realized* per-axis shrink factor `%{w: float, h: float}`
    (each `>= 1.0`, original ÷ decoded) actually applied by shrink-on-load, or `nil`
    when the decode was full-resolution. A crop preceding the resize rescales its
    absolute pixel dims and pixel/absolute gravity offsets by this factor so the
    crop selects the same source region on the shrunk image that it would at full
    resolution; relative (ratio/percent/focus-point) coordinates are untouched.
    Integer decoded dimensions can make the realized factors differ between axes.
    Its axes follow the current image. A gravity crop carrying a pending
    quarter-turn swaps the per-axis factors before rescaling; the crop dimensions
    are then mapped back into the current image frame.
  - `source_color_profile` and `color_imported?`: carry the input-color-management
    result from the preamble (`ImagePipe.Transform.InputColorManagement`) to the
    delivery-boundary stamp. `source_color_profile` is the raw source ICC bytes
    (or `nil`), and `color_imported?` indicates whether an actual `icc_import` ran.
    Transform-domain data; must never be emitted in telemetry metadata.
  """

  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
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
          detector: module() | {module(), keyword()} | nil,
          detector_required: boolean(),
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
  Dimensions the residual resize must size against.

  When shrink-on-load reduced the decoded image, this returns the exact stored
  original extent (`source_dimensions`), so the residual resize computes the same
  target a full-resolution decode would. With no shrink it returns the live image
  dimensions — which also makes a crop-before-resize correct, since the cropped
  image's own dimensions are what the following resize should size against.
  """
  def effective_source_dims(%__MODULE__{source_dimensions: {w, h}}), do: {w, h}

  def effective_source_dims(%__MODULE__{image: image}),
    do: {Image.width(image), Image.height(image)}
end
