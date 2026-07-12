# Baked by ImagePipe.Test.ResolvedPlanCases.bake!/0 — the executed op /
# materialize sequence and realized per-op dims of the PRE-cutover,
# OrientationScheduler-driven pipeline, recorded as the golden
# `expected` data for the ResolvedPlan golden test. Do not edit by hand.
[
  %{
    name: :plain_fit,
    path: "/unsafe/rs:fit:200:150/plain/local:///high_freq.jpg",
    opts: "rs:fit:200:150",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: {:pixels, 200},
         height: {:pixels, 150},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {200, 150}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: {1600, 1200},
      decode_shrink: %{h: 8.0, w: 8.0},
      original_dims: {1600, 1200},
      decoded_dims: {200, 150}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {200, 150},
    final_materialized: false
  },
  %{
    name: :cover_result_crop,
    path: "/unsafe/rs:fill:240:180/g:no/plain/local:///high_freq.jpg",
    opts: "rs:fill:240:180/g:no",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fill,
         width: {:pixels, 240},
         height: {:pixels, 180},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {240, 180}, :ok},
      {:op_start, :crop, 1,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 240},
         height: {:pixels, 180},
         crop_from: :gravity,
         gravity: {:anchor, :center, :top},
         x_offset: {:pixels, 0.0},
         y_offset: {:pixels, 0.0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :near}
       }},
      {:op_stop, :crop, 1, {240, 180}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: {1600, 1200},
      decode_shrink: %{h: 4.0, w: 4.0},
      original_dims: {1600, 1200},
      decoded_dims: {400, 300}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {240, 180},
    final_materialized: false
  },
  %{
    name: :auto_landscape_cover,
    path: "/unsafe/rs:auto:300:200/plain/local:///high_freq.jpg",
    opts: "rs:auto:300:200",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fill,
         width: {:pixels, 300},
         height: {:pixels, 200},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {300, 225}, :ok},
      {:op_start, :crop, 1,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 300},
         height: {:pixels, 200},
         crop_from: :gravity,
         gravity: {:anchor, :center, :center},
         x_offset: {:pixels, 0.0},
         y_offset: {:pixels, 0.0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :near}
       }},
      {:op_stop, :crop, 1, {300, 200}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: {1600, 1200},
      decode_shrink: %{h: 4.0, w: 4.0},
      original_dims: {1600, 1200},
      decoded_dims: {400, 300}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {300, 200},
    final_materialized: false
  },
  %{
    name: :auto_portrait_fit,
    path: "/unsafe/rs:auto:200:300/plain/local:///high_freq.jpg",
    opts: "rs:auto:200:300",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: {:pixels, 200},
         height: {:pixels, 300},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {200, 150}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: {1600, 1200},
      decode_shrink: %{h: 4.0, w: 4.0},
      original_dims: {1600, 1200},
      decoded_dims: {400, 300}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {200, 150},
    final_materialized: false
  },
  %{
    name: :min_width_coupling,
    path: "/unsafe/rs:fit:300:300/mw:280/mh:280/plain/local:///high_freq.jpg",
    opts: "rs:fit:300:300/mw:280/mh:280",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: {:pixels, 300},
         height: {:pixels, 300},
         min_width: {:pixels, 280},
         min_height: {:pixels, 280},
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {373, 280}, :ok},
      {:op_start, :crop, 1,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 300},
         height: {:pixels, 300},
         crop_from: :gravity,
         gravity: {:anchor, :center, :center},
         x_offset: {:pixels, 0.0},
         y_offset: {:pixels, 0.0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :near}
       }},
      {:op_stop, :crop, 1, {300, 280}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {1600, 1200},
      decoded_dims: {1600, 1200}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {300, 280},
    final_materialized: false
  },
  %{
    name: :dpr_cap_no_geometry,
    path: "/unsafe/pd:10:4:2:8/dpr:2/plain/local:///small.png",
    opts: "pd:10:4:2:8/dpr:2",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: :auto,
         height: :auto,
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 2.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {120, 90}, :ok},
      {:op_start, :padding, 0,
       %ImagePipe.Transform.Operation.Padding{
         top: 10,
         right: 4,
         bottom: 2,
         left: 8,
         fill: :transparent
       }},
      {:op_stop, :padding, 0, {132, 102}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {120, 90},
      decoded_dims: {120, 90}
    },
    source: "small.png",
    auto_rotate: true,
    final_dims: {132, 102},
    final_materialized: false
  },
  %{
    name: :quarter_turn_cover,
    path: "/unsafe/rs:fill:60:80/plain/local:///exif_6.jpg",
    opts: "rs:fill:60:80",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :force,
         width: {:pixels, 80},
         height: {:pixels, 60},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: true,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {80, 60}, :ok},
      {:op_start, :crop, 1,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 80},
         height: {:pixels, 60},
         crop_from: :gravity,
         gravity: {:anchor, :center, :center},
         x_offset: {:pixels, 0.0},
         y_offset: {:pixels, -0.0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :far}
       }},
      {:op_stop, :crop, 1, {80, 60}, :ok},
      {:materialize_start},
      {:materialize_stop, {60, 80}, :ok}
    ],
    seed: %{
      exif_orientation: 6,
      source_dimensions: {400, 300},
      decode_shrink: %{h: 4.0, w: 4.0},
      original_dims: {400, 300},
      decoded_dims: {100, 75}
    },
    source: "exif_6.jpg",
    auto_rotate: true,
    final_dims: {60, 80},
    final_materialized: true
  },
  %{
    name: :shrink_crop_resize,
    path: "/unsafe/c:800:600:nowe/rs:fit:100:100/plain/local:///high_freq.jpg",
    opts: "c:800:600:nowe/rs:fit:100:100",
    events: [
      {:op_start, :crop, 0,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 200},
         height: {:pixels, 150},
         crop_from: :gravity,
         gravity: {:anchor, :left, :top},
         x_offset: {:pixels, 0},
         y_offset: {:pixels, 0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :near}
       }},
      {:op_stop, :crop, 0, {200, 150}, :ok},
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: {:pixels, 100},
         height: {:pixels, 100},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {100, 75}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: {1600, 1200},
      decode_shrink: %{h: 4.0, w: 4.0},
      original_dims: {1600, 1200},
      decoded_dims: {400, 300}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {100, 75},
    final_materialized: false
  },
  %{
    name: :trim_pending_quarter_turn,
    path: "/unsafe/t:10/plain/local:///exif_6.jpg",
    opts: "t:10",
    events: [
      {:materialize_start},
      {:materialize_stop, {400, 300}, :ok},
      {:op_start, :trim, 0,
       %ImagePipe.Transform.Operation.Trim{
         threshold: 10.0,
         background: :auto,
         equal_hor: false,
         equal_ver: false
       }},
      {:op_stop, :trim, 0, {400, 300}, :ok},
      {:materialize_start},
      {:materialize_stop, {300, 400}, :ok}
    ],
    seed: %{
      exif_orientation: 6,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {400, 300},
      decoded_dims: {400, 300}
    },
    source: "exif_6.jpg",
    auto_rotate: true,
    final_dims: {300, 400},
    final_materialized: true
  },
  %{
    name: :fill_down_target_gt_source,
    path: "/unsafe/rs:fill-down:600:400/plain/local:///small.png",
    opts: "rs:fill-down:600:400",
    events: [
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fill_down,
         width: {:pixels, 600},
         height: {:pixels, 400},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {120, 90}, :ok},
      {:op_start, :crop, 1,
       %ImagePipe.Transform.Operation.Crop{
         width: {:pixels, 120},
         height: {:pixels, 80},
         crop_from: :gravity,
         gravity: {:anchor, :center, :center},
         x_offset: {:pixels, 0.0},
         y_offset: {:pixels, 0.0},
         offset_scale: 1.0,
         aspect_ratio: nil,
         enlarge: false,
         reject_out_of_bounds: false,
         center_bias: {:near, :near}
       }},
      {:op_stop, :crop, 1, {120, 80}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {120, 90},
      decoded_dims: {120, 90}
    },
    source: "small.png",
    auto_rotate: true,
    final_dims: {120, 80},
    final_materialized: false
  },
  %{
    name: :trim_resize_padding,
    path: "/unsafe/t:10/rs:fit:400:300/pd:12:12:12:12/plain/local:///border_asym.png",
    opts: "t:10/rs:fit:400:300/pd:12:12:12:12",
    events: [
      {:op_start, :trim, 0,
       %ImagePipe.Transform.Operation.Trim{
         threshold: 10.0,
         background: :auto,
         equal_hor: false,
         equal_ver: false
       }},
      {:materialize_start},
      {:materialize_stop, {1600, 1200}, :ok},
      {:op_stop, :trim, 0, {1300, 1000}, :ok},
      {:op_start, :resize, 0,
       %ImagePipe.Transform.Operation.Resize{
         mode: :fit,
         width: {:pixels, 400},
         height: {:pixels, 300},
         min_width: nil,
         min_height: nil,
         zoom_x: 1.0,
         zoom_y: 1.0,
         dpr: 1.0,
         enlarge: false,
         reject_enlargement: false,
         max_width: nil,
         max_height: nil,
         max_area: nil
       }},
      {:op_stop, :resize, 0, {390, 300}, :ok},
      {:op_start, :padding, 0,
       %ImagePipe.Transform.Operation.Padding{
         top: 12,
         right: 12,
         bottom: 12,
         left: 12,
         fill: :transparent
       }},
      {:op_stop, :padding, 0, {414, 324}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {1600, 1200},
      decoded_dims: {1600, 1200}
    },
    source: "border_asym.png",
    auto_rotate: true,
    final_dims: {414, 324},
    final_materialized: true
  },
  %{
    name: :identity_streaming,
    path: "/unsafe/bl:2/plain/local:///high_freq.jpg",
    opts: "bl:2",
    events: [
      {:op_start, :blur, 0, %ImagePipe.Transform.Operation.Blur{sigma: 2.0}},
      {:op_stop, :blur, 0, {1600, 1200}, :ok}
    ],
    seed: %{
      exif_orientation: 1,
      source_dimensions: nil,
      decode_shrink: nil,
      original_dims: {1600, 1200},
      decoded_dims: {1600, 1200}
    },
    source: "high_freq.jpg",
    auto_rotate: true,
    final_dims: {1600, 1200},
    final_materialized: false
  }
]
