defmodule ImagePipe.Test.Golden.Cases do
  @moduledoc """
  Requests whose output is compared against goldens baked from ImagePipe itself.

  Goldens record current behaviour, bugs included: a failure means the output
  changed, not that it is wrong. Re-bake with `mix image_pipe.golden.bake` when a
  change is intended and review the changed images. A case's `:changes_with`
  names the issues whose fix is expected to change it; any other golden that
  moves in that work is a regression.

  `:png` cases render as PNG; `:encoded` cases render their own format and
  compare decoded pixels. Tolerances are `{threshold, budget}` as in the
  imgproxy reference suite.
  """
  use Boundary, top_level?: true, deps: []

  @type t :: %{
          optional(:changes_with) => [String.t()],
          id: String.t(),
          kind: :png | :encoded,
          source: String.t(),
          native: String.t(),
          tolerance: {non_neg_integer(), non_neg_integer()}
        }

  @spec all() :: [t()]
  def all do
    [
      # ImagePipe-only options on sRGB sources.
      %{
        id: "colorize",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/colorize=0.3,ff0000",
        tolerance: {2, 64}
      },
      %{
        id: "colorize_keep_alpha",
        kind: :png,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/colorize=0.5,0000ff,keep-alpha",
        tolerance: {2, 64}
      },
      %{
        id: "duotone",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/duotone=1,123456,efab89",
        tolerance: {2, 64}
      },
      %{
        id: "monochrome",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/monochrome=0.8,704214",
        tolerance: {2, 64}
      },
      %{
        id: "gray",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/gray",
        tolerance: {2, 64}
      },
      %{
        id: "bitonal",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/bitonal",
        tolerance: {2, 64}
      },
      %{
        id: "brightness",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/brightness=30",
        tolerance: {2, 64}
      },
      %{
        id: "contrast",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/contrast=1.5",
        tolerance: {2, 64}
      },
      %{
        id: "saturation",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/saturation=0.7",
        tolerance: {2, 64}
      },
      %{
        id: "gradient_down",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/gradient=0.8,black,down,0.2,0.9",
        tolerance: {2, 64}
      },
      %{
        id: "gradient_right",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/gradient=0.6,ff0000,right",
        tolerance: {2, 64}
      },
      %{
        id: "progressive_blur",
        kind: :png,
        source: "high_freq.jpg",
        native: "w=400/h=300/fit=contain/progressive-blur=4,down,0.2,0.8",
        tolerance: {2, 64}
      },
      %{
        id: "crop_ratio",
        kind: :png,
        source: "placement.png",
        native: "crop=800,800/crop-ratio=16:9",
        tolerance: {2, 64}
      },
      %{
        id: "crop_ratio_enlarge",
        kind: :png,
        source: "placement.png",
        native: "crop=800,400/crop-ratio=1:1/crop-ratio-enlarge",
        tolerance: {2, 64}
      },
      %{
        id: "rotate_30",
        kind: :png,
        source: "placement.png",
        native: "rotate=30/w=400/h=300/fit=contain",
        tolerance: {2, 64}
      },
      %{
        id: "rotate_30_alpha",
        kind: :png,
        source: "alpha_border.png",
        native: "rotate=30",
        tolerance: {2, 64}
      },
      %{
        id: "rotate_45_bg",
        kind: :png,
        source: "small.png",
        native: "rotate=45/bg=ffffff",
        tolerance: {2, 64}
      },
      %{
        id: "region",
        kind: :png,
        source: "placement.png",
        native: "region=100,50,400,300",
        tolerance: {2, 64}
      },
      # Each group works on the previous group's output.
      %{
        id: "group_chain",
        kind: :png,
        source: "placement.png",
        native: "w=800/h=600/fit=contain/-/crop=300,200/anchor=right/-/blur=2",
        tolerance: {2, 64}
      },
      # DPR applies to its own group only: the second padding is 1x.
      %{
        id: "group_dpr_reset",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=contain/dpr=2/pad=5/-/pad=5",
        tolerance: {2, 64}
      },
      %{
        id: "wm_tile_gap",
        kind: :png,
        source: "placement.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-tile/wm-gap=10,20/wm-scale=0.1",
        tolerance: {2, 64}
      },
      # Natural-size watermark scales with DPR.
      %{
        id: "wm_natural_dpr",
        kind: :png,
        source: "marker.png",
        native: "w=200/h=150/fit=contain/dpr=2/wm=mark/wm-at=bottom-right/wm-offset=10,10",
        tolerance: {2, 64}
      },
      %{
        id: "wm_opacity_pct_offset",
        kind: :png,
        source: "placement.png",
        native:
          "w=400/h=300/fit=contain/wm=mark/wm-opacity=0.4/wm-at=top-right/wm-offset=5pct,10pct/wm-scale=0.3",
        tolerance: {2, 64}
      },
      # Deliberate differences from imgproxy (see the reference README).
      # Minimum dimensions expand the target; nothing crops back to the box.
      %{
        id: "min_w_beyond_box",
        kind: :png,
        source: "marker.png",
        native: "w=300/h=300/fit=contain/min-w=400",
        tolerance: {2, 64}
      },
      %{
        id: "cover_min_dims_above_box",
        kind: :png,
        source: "placement.png",
        native: "w=200/h=200/fit=cover/min-w=400/min-h=400",
        tolerance: {2, 64}
      },
      # DPR scales padding even without a resize.
      %{
        id: "pad_dpr_no_resize",
        kind: :png,
        source: "exif_6.jpg",
        native: "pad=10,4,2,8/dpr=2",
        tolerance: {2, 64}
      },
      # trim=auto samples the displayed top-left corner.
      %{
        id: "trim_auto_display_corner",
        kind: :png,
        source: "exif_6.jpg",
        native: "trim=auto",
        tolerance: {2, 64}
      },
      # Without enlargement, cover keeps the requested box's ratio.
      %{
        id: "strip_cover_small",
        kind: :png,
        source: "strip.png",
        native: "w=50/h=50/fit=cover",
        tolerance: {2, 64}
      },
      # Centring rounds the same way in every orientation.
      %{
        id: "rotate_crop_centered",
        kind: :png,
        source: "gray.png",
        native: "rotate=90/crop=150,200/anchor=top",
        tolerance: {2, 64}
      },
      %{
        id: "exif_pct_crop_centered",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "crop=50pct,50pct/anchor=top",
        tolerance: {2, 64}
      },
      # Attention scoring runs in the displayed frame.
      %{
        id: "exif_smart_crop",
        kind: :png,
        source: "exif_placement_6.jpg",
        native: "crop=200,200/anchor=smart",
        tolerance: {2, 64}
      },
      # Output encoding: lossy formats compare decoded pixels.
      %{
        id: "jpeg_q80",
        kind: :encoded,
        source: "high_freq.jpg",
        native: "w=300/h=200/fit=contain/format=jpeg/q=80",
        tolerance: {24, 512}
      },
      %{
        id: "webp_q80",
        kind: :encoded,
        source: "high_freq.jpg",
        native: "w=300/h=200/fit=contain/format=webp/q=80",
        tolerance: {24, 512}
      },
      %{
        id: "avif_q60",
        kind: :encoded,
        source: "high_freq.jpg",
        native: "w=300/h=200/fit=contain/format=avif/q=60",
        tolerance: {24, 512}
      },
      %{
        id: "jpeg_progressive",
        kind: :encoded,
        source: "placement.png",
        native: "w=300/h=200/fit=contain/format=jpeg/jpeg-options=progressive",
        tolerance: {24, 512}
      },
      %{
        id: "webp_lossless",
        kind: :encoded,
        source: "placement.png",
        native: "w=300/h=200/fit=contain/format=webp/webp-options=lossless",
        tolerance: {2, 64}
      },
      %{
        id: "png_palette",
        kind: :encoded,
        source: "placement.png",
        native: "w=300/h=200/fit=contain/format=png/png-options=palette",
        tolerance: {2, 64}
      },
      %{
        id: "jpeg_alpha_flatten",
        kind: :encoded,
        source: "alpha.png",
        native: "w=128/h=128/fit=contain/format=jpeg",
        tolerance: {24, 512}
      },
      %{
        id: "profile_display_p3",
        kind: :png,
        source: "placement.png",
        native: "w=300/h=200/fit=contain/profile=display-p3",
        tolerance: {2, 64}
      },
      %{
        id: "profile_adobe_rgb",
        kind: :png,
        source: "placement.png",
        native: "w=300/h=200/fit=contain/profile=adobe-rgb",
        tolerance: {2, 64}
      },
      %{
        id: "hdr_preserve_rgb16",
        kind: :png,
        source: "rgb16.png",
        native: "w=200/h=200/fit=contain/hdr=preserve",
        tolerance: {2, 64}
      },
      # Colour on grayscale.
      # A neutral background keeps its gray value (128).
      %{
        id: "gray_pad_bg_neutral",
        kind: :png,
        source: "gray.png",
        native: "w=200/h=150/fit=contain/pad=10/bg=808080",
        tolerance: {2, 64}
      },
      %{
        id: "gray_extend_bg_red",
        kind: :png,
        source: "gray.png",
        native: "w=300/h=300/fit=contain/extend/bg=ff0000",
        tolerance: {2, 64},
        changes_with: ["image_plug-dr1"]
      },
      %{
        id: "gray_watermark_colour",
        kind: :png,
        source: "gray.png",
        native: "w=400/h=300/fit=contain/wm=mark/wm-at=bottom-right/wm-scale=0.25",
        tolerance: {2, 64},
        changes_with: ["image_plug-dr1"]
      },
      %{
        id: "gray_colorize",
        kind: :png,
        source: "gray.png",
        native: "w=200/h=150/fit=contain/colorize=0.5,ff0000",
        tolerance: {2, 64},
        changes_with: ["image_plug-34z"]
      },
      # Wide gamut and 16-bit colour.
      %{
        id: "p3_preserve_fit",
        kind: :png,
        source: "icc_p3.png",
        native: "w=200/h=200/fit=contain/profile=preserve",
        tolerance: {2, 64},
        changes_with: ["image_plug-qud"]
      },
      %{
        id: "p3_preserve_blur",
        kind: :png,
        source: "icc_p3.png",
        native: "w=200/h=200/fit=contain/profile=preserve/blur=3",
        tolerance: {2, 64},
        changes_with: ["image_plug-qud"]
      },
      %{
        id: "p3_strip_fit",
        kind: :png,
        source: "icc_p3.png",
        native: "w=200/h=200/fit=contain",
        tolerance: {2, 64},
        changes_with: ["image_plug-qud"]
      },
      %{
        id: "p3_strip_bg_extend",
        kind: :png,
        source: "icc_p3.png",
        native: "w=300/h=200/fit=contain/extend/bg=4080c0",
        tolerance: {2, 64},
        changes_with: ["image_plug-qud", "image_plug-34z"]
      },
      %{
        id: "p3_preserve_bg_extend",
        kind: :png,
        source: "icc_p3.png",
        native: "w=300/h=200/fit=contain/extend/bg=ff0000/profile=preserve",
        tolerance: {2, 64},
        changes_with: ["image_plug-qud", "image_plug-34z"]
      },
      %{
        id: "rgb16_colorize",
        kind: :png,
        source: "rgb16.png",
        native: "w=200/h=200/fit=contain/hdr=preserve/colorize=0.5,ff0000",
        tolerance: {2, 64},
        changes_with: ["image_plug-34z"]
      },
      %{
        id: "rgb16_gradient",
        kind: :png,
        source: "rgb16.png",
        native: "w=200/h=200/fit=contain/hdr=preserve/gradient=0.8,black,down",
        tolerance: {2, 64},
        changes_with: ["image_plug-34z"]
      },
      %{
        id: "rgb16_duotone",
        kind: :png,
        source: "rgb16.png",
        native: "w=200/h=200/fit=contain/hdr=preserve/duotone=1,123456,efab89",
        tolerance: {2, 64},
        changes_with: ["image_plug-34z"]
      },
      %{
        id: "rgb16_gray",
        kind: :png,
        source: "rgb16.png",
        native: "w=200/h=200/fit=contain/hdr=preserve/gray",
        tolerance: {2, 64},
        changes_with: ["image_plug-34z"]
      }
    ]
  end
end
