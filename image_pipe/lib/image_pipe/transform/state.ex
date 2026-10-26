defmodule ImagePipe.Transform.State do
  # Execution state carried through a transform chain.
  #
  # Holds the current image, debug flag, and runtime configuration. Operations
  # return updated state and access host collaborators without depending on request
  # modules:
  #
  # - `detector`: host-configured content detector module, or `nil` when no
  #   detector is configured.
  # - `detector_required`: the mount's `detector_required`. A detection error
  #   fails the request instead of falling back to attention.
  # - `degraded?`: a crop fell back to attention because detection returned an
  #   error. The output must not be stored or given a validator, so a later
  #   request can retry detection.
  # - `telemetry_opts`: telemetry metadata threaded through stage spans.
  # - `materialized?`: the graph has RAM-backed input and can be read out of row
  #   order without revisiting the sequential source. Later operations may remain
  #   lazy; this does not imply the current result is a contiguous pixel buffer.
  # - `rebuffer?`: the current graph ends in lazy work that overlapping reads
  #   would repeat: an arbitrary rotation, a blur or sharpen, or an input
  #   color conversion. Resize and random-access steps buffer it first;
  #   materialization and orientation flush clear the flag.
  # - `lazy_steps`: the operations run since the image was last copied to
  #   memory. libvips recurses through the whole lazy graph when it reads or
  #   frees it, and a deep graph overflows a native thread's stack, so
  #   `ImagePipe.Transform.Executor.Step` copies the image after a few.
  # - `blur_work`: the work of the blurs and sharpens run so far in this
  #   request, which together can't exceed `max_blur_work`.
  # - `source_dimensions`: exact full-resolution `{w, h}` before shrink-on-load,
  #   or `nil` for a full-resolution decode. Residual resize uses this extent to
  #   match the full-resolution target. Pending orientation maps its axes to the
  #   display frame; a physical quarter-turn flush swaps the extent and shrink
  #   axes. Resize consumes the extent. Crop, trim, arbitrary rotation, canvas,
  #   and padding establish new geometry; the executor clears the extent and
  #   decode scale at those boundaries.
  # - `decode_shrink`: realized per-axis factors `%{w: float, h: float}`
  #   (original ÷ decoded), or `nil` for a full-resolution decode. Each factor
  #   is `>= 1.0` except for a vector source, which can render larger.
  #   Crops before resize rescale absolute dimensions and gravity offsets to
  #   select the same source region; relative coordinates stay unchanged. Integer
  #   decode dimensions can yield different factors per axis. Factors follow the
  #   current image axes: gravity crops swap them for a pending quarter turn, then
  #   map crop dimensions back to the image frame.
  # - `vector?`: the source is a vector image rendered at the decode scale, so
  #   the first group's resize isn't clamped to the source's intrinsic size.
  #   False when it rendered at its intrinsic size, as for a first group that
  #   trims, since enlarging that render would only resample it.
  # - `dpr`: the effective DPR of the most recently executed group, after the
  #   enlargement clamp and its floor; 1.0 before any group runs.
  # - `detections`: how many detections a crop ran, for the cache's cost
  #   estimate. A call to a detector unavailable in this build doesn't count.
  # - `detection_frame`: the in-memory display frame a resize's detection crop
  #   detects on, taken before the resize so the detector gets enough pixels, or
  #   `nil` to detect on the current image.
  # - `source_color_profile` and `color_imported?`: input-color-management results
  #   passed to the encoder. The profile holds raw source ICC bytes or `nil`; the
  #   flag records whether `icc_import` ran. Never emit these in telemetry metadata.
  @moduledoc false

  defstruct image: nil,
            debug: false,
            detector: nil,
            detector_required: false,
            degraded?: false,
            telemetry_opts: [],
            source_dimensions: nil,
            decode_shrink: nil,
            vector?: false,
            pending_orientation: nil,
            materialized?: false,
            max_intermediate_pixels: 100_000_000,
            max_blur_work: 4_000_000_000_000,
            blur_work: 0,
            rebuffer?: false,
            lazy_steps: 0,
            dpr: 1.0,
            detections: 0,
            detection_frame: nil,
            source_color_profile: nil,
            color_imported?: false

  @type t :: %__MODULE__{
          image: Vix.Vips.Image.t() | nil,
          debug: boolean(),
          detector: module() | nil,
          detector_required: boolean(),
          degraded?: boolean(),
          telemetry_opts: keyword(),
          source_dimensions: {pos_integer(), pos_integer()} | nil,
          decode_shrink: %{w: float(), h: float()} | nil,
          vector?: boolean(),
          pending_orientation: ImagePipe.Transform.PendingOrientation.t() | nil,
          materialized?: boolean(),
          max_intermediate_pixels: pos_integer(),
          max_blur_work: pos_integer() | :infinity,
          blur_work: non_neg_integer(),
          rebuffer?: boolean(),
          lazy_steps: non_neg_integer(),
          dpr: float(),
          detections: non_neg_integer(),
          detection_frame: Vix.Vips.Image.t() | nil,
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
