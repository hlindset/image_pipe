defmodule ImagePipe.Plan.Operation.Resize do
  @moduledoc """
  Product-neutral semantic resize intent.

  `down: true` qualifies a `:cover` resize as the "don't scale up" variant: the
  image is never enlarged to fill the box, and when it is smaller than the box the
  result is cropped to the requested aspect ratio instead of left at its own
  (imgproxy's `fill-down`). It maps to the transform layer's `:fill_down` mode.
  """

  @enforce_keys [:mode, :width, :height, :dpr, :enlargement, :guide]
  defstruct @enforce_keys ++
              [
                down: false,
                x_offset: {:pixels, 0.0},
                y_offset: {:pixels, 0.0},
                min_width: nil,
                min_height: nil,
                zoom_x: 1.0,
                zoom_y: 1.0,
                max_width: nil,
                max_height: nil,
                max_area: nil
              ]

  @type mode :: :fit | :cover | :stretch | :auto
  @type dimension :: :auto | {:px, pos_integer()} | {:ratio, pos_integer(), pos_integer()}
  @type dpr :: {:ratio, pos_integer(), pos_integer()}
  @type enlargement :: :allow | :deny | :reject
  @type anchor :: :left | :center | :right | :top | :bottom
  @type weights :: %{optional(:default) => number(), optional(String.t()) => number()}
  @type guide ::
          :center
          # requires a point-carrying resolver strategy
          | :deferred
          | {:anchor, anchor(), anchor()}
          | {:focal, ratio(), ratio()}
          | :smart
          | {:smart, :face_assist}
          | {:detect, {:all, weights()}}
          | {:detect, {nonempty_list(String.t()), weights()}}
  @type ratio :: {:ratio, non_neg_integer(), pos_integer()}
  @type offset :: number() | {:pixels | :scale, number()}
  # A zoom factor is a positive number or an exact positive ratio. The ratio form
  # carries a relative size (IIIF `pct:n`) without an early lossy `num/den` float,
  # so the derived axis rounds exactly at a tie (#317).
  @type zoom :: pos_integer() | float() | {:ratio, pos_integer(), pos_integer()}

  @type t :: %__MODULE__{
          mode: mode(),
          width: dimension(),
          height: dimension(),
          dpr: dpr(),
          down: boolean(),
          enlargement: enlargement(),
          guide: guide(),
          x_offset: offset(),
          y_offset: offset(),
          min_width: dimension() | nil,
          min_height: dimension() | nil,
          zoom_x: zoom(),
          zoom_y: zoom(),
          max_width: pos_integer() | nil,
          max_height: pos_integer() | nil,
          max_area: pos_integer() | nil
        }
end
