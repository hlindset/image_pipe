defmodule ImagePipe.Dialect.Imgproxy.PipelineRequest do
  @moduledoc false

  alias ImagePipe.Dialect.Imgproxy.CropRequest
  alias ImagePipe.Dialect.Imgproxy.Effects
  alias ImagePipe.Dialect.Imgproxy.Orientation
  alias ImagePipe.Plan.Color

  @type resizing_type() :: :fit | :fill | :fill_down | :force | :auto
  @type gravity_anchor() :: {:anchor, :left | :center | :right, :top | :center | :bottom}
  @type gravity() :: gravity_anchor() | {:fp, float(), float()} | :sm
  @type gravity_offset() :: {:pixels, float()} | {:scale, float()}

  @type t() :: %__MODULE__{
          width: ImagePipe.imgp_pixels() | nil,
          height: ImagePipe.imgp_pixels() | nil,
          min_width: ImagePipe.imgp_pixels() | nil,
          min_height: ImagePipe.imgp_pixels() | nil,
          resizing_type: resizing_type(),
          zoom_x: float() | nil,
          zoom_y: float() | nil,
          dpr: float() | nil,
          enlarge: boolean(),
          extend: boolean(),
          extend_requested: boolean(),
          extend_gravity: gravity_anchor() | nil,
          extend_x_offset: float() | nil,
          extend_y_offset: float() | nil,
          extend_aspect_ratio: boolean(),
          extend_aspect_ratio_gravity: gravity_anchor() | nil,
          extend_aspect_ratio_x_offset: float() | nil,
          extend_aspect_ratio_y_offset: float() | nil,
          padding_top: non_neg_integer(),
          padding_right: non_neg_integer(),
          padding_bottom: non_neg_integer(),
          padding_left: non_neg_integer(),
          background_color: Color.t() | nil,
          background_alpha: Color.alpha() | nil,
          effects: Effects.t(),
          gravity: gravity(),
          gravity_x_offset: gravity_offset(),
          gravity_y_offset: gravity_offset(),
          crop: CropRequest.t() | nil,
          crop_aspect_ratio: float() | nil,
          crop_aspect_ratio_enlarge: boolean(),
          trim: keyword() | nil,
          orientation_requested: boolean(),
          auto_rotate_requested: boolean(),
          strip_color_profile: boolean(),
          strip_color_profile_requested: boolean(),
          color_profile: :srgb | :display_p3 | :adobe_rgb | nil,
          smart_crop_face_detection: boolean(),
          orientation: Orientation.t()
        }

  # One flat accumulator for the many independent imgproxy URL options a
  # single pipeline can carry; the fields are deliberately wide rather
  # than grouped into artificial sub-structs.
  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct width: nil,
            height: nil,
            min_width: nil,
            min_height: nil,
            resizing_type: :fit,
            zoom_x: nil,
            zoom_y: nil,
            dpr: nil,
            enlarge: false,
            extend: false,
            extend_requested: false,
            extend_gravity: nil,
            extend_x_offset: nil,
            extend_y_offset: nil,
            extend_aspect_ratio: false,
            extend_aspect_ratio_gravity: nil,
            extend_aspect_ratio_x_offset: nil,
            extend_aspect_ratio_y_offset: nil,
            padding_top: 0,
            padding_right: 0,
            padding_bottom: 0,
            padding_left: 0,
            background_color: nil,
            background_alpha: nil,
            effects: %Effects{},
            gravity: {:anchor, :center, :center},
            gravity_x_offset: {:pixels, 0.0},
            gravity_y_offset: {:pixels, 0.0},
            crop: nil,
            crop_aspect_ratio: nil,
            crop_aspect_ratio_enlarge: false,
            trim: nil,
            orientation_requested: false,
            auto_rotate_requested: false,
            strip_color_profile: false,
            strip_color_profile_requested: false,
            color_profile: nil,
            smart_crop_face_detection: false,
            orientation: %Orientation{}
end
