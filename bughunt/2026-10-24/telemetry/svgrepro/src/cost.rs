use resvg::tiny_skia::{PathSegment, Point, Rect, Transform};
use resvg::usvg::{self, Group, ImageKind, Node, Paint, filter};

/// Work units per drawn path or image, whatever its size. Without it, many
/// tiny paths look free: 100,000 of them cover few pixels but take as long
/// to render as about 30 million pixels of layers.
const PER_NODE: f64 = 200.0;

/// Work units per pixel of a stroked curve's control polygon. Stroking
/// subdivides each curve by its length on the canvas, so a chain of curves
/// with far-flung control points costs far more than the area it covers.
/// Measured at about 55 ns per pixel on an Apple M-series laptop, across
/// render sizes from 64 to 1024 pixels, which its calibrated rate puts at
/// about 8.5 units.
const STROKED_CURVE_PER_PX: f64 = 10.0;

/// What rendering a tree at a size will cost, estimated before rendering.
///
/// `work` counts pixels pushed through offscreen pixmaps, weighting filter
/// primitives by how much slower than a plain layer they run. `peak` is the
/// most pixmap pixels alive at once, including the canvas.
pub struct Cost {
    pub work: u64,
    pub peak: u64,
    pub images: u64,
    pub image_pixels: u64,
    /// How far from the canvas's origin any drawn path or image reaches, in
    /// pixels, counting control points and stroke width.
    pub extent: f64,
}

/// Walks the tree the way resvg renders it: an isolated group renders into a
/// layer, then applies its filters, clip path, and mask, each in pixmaps the
/// layer's size, all alive until the layer is composited. Layers and filter
/// regions are clipped to resvg's bound of 5× the canvas per axis. Pattern
/// tiles aren't bounded. Shared definitions are walked once per reference,
/// since resvg renders them once per reference.
pub fn estimate(tree: &usvg::Tree, width: u32, height: u32) -> Cost {
    let (w, h) = (width as f32, height as f32);
    let size = tree.size();
    let mut walk = Walk {
        bound: Rect::from_xywh(-2.0 * w, -2.0 * h, 5.0 * w, 5.0 * h).unwrap(),
        canvas: f64::from(w) * f64::from(h),
        work: 0.0,
        live: 0.0,
        peak: 0.0,
        images: 0,
        image_pixels: 0,
        extent: 0.0,
    };
    let ts = Transform::from_scale(w / size.width(), h / size.height());
    walk.alloc(walk.canvas, |walk| walk.nodes(tree.root(), ts));

    Cost {
        work: walk.work as u64,
        peak: walk.peak as u64,
        images: walk.images,
        image_pixels: walk.image_pixels,
        extent: walk.extent,
    }
}

struct Walk {
    bound: Rect,
    canvas: f64,
    work: f64,
    live: f64,
    peak: f64,
    images: u64,
    image_pixels: u64,
    extent: f64,
}

impl Walk {
    fn alloc(&mut self, pixels: f64, render: impl FnOnce(&mut Self)) {
        self.live += pixels;
        self.peak = self.peak.max(self.live);
        render(self);
        self.live -= pixels;
    }

    fn area(&self, rect: Option<Rect>) -> f64 {
        rect.and_then(|rect| rect.intersect(&self.bound))
            .map_or(0.0, |rect| {
                f64::from(rect.width()) * f64::from(rect.height())
            })
    }

    fn nodes(&mut self, parent: &Group, ts: Transform) {
        for node in parent.children() {
            match node {
                Node::Group(group) => self.group(group, ts),
                Node::Path(path) => self.path(path, ts),
                Node::Image(image) => self.image(image, ts),
                Node::Text(text) => self.nodes(text.flattened(), ts),
            }
        }
    }

    fn group(&mut self, group: &Group, ts: Transform) {
        let ts = ts.pre_concat(group.transform());
        if !group.should_isolate() {
            self.nodes(group, ts);
            return;
        }

        let layer = self.area(
            group
                .layer_bounding_box()
                .transform(ts)
                .map(|r| r.to_rect()),
        );
        self.alloc(layer, |walk| {
            walk.work += layer;
            walk.nodes(group, ts);
            for filter in group.filters() {
                walk.filter(filter, ts);
            }
            if let Some(clip) = group.clip_path() {
                walk.clip(clip, ts, layer);
            }
            if let Some(mask) = group.mask() {
                walk.mask(mask, ts, layer);
            }
        });
    }

    fn clip(&mut self, clip: &usvg::ClipPath, ts: Transform, layer: f64) {
        self.alloc(layer, |walk| {
            walk.work += layer;
            walk.nodes(clip.root(), ts.pre_concat(clip.transform()));
            if let Some(inner) = clip.clip_path() {
                walk.clip(inner, ts, layer);
            }
        });
    }

    fn mask(&mut self, mask: &usvg::Mask, ts: Transform, layer: f64) {
        self.alloc(layer, |walk| {
            walk.work += layer;
            walk.nodes(mask.root(), ts);
            if let Some(inner) = mask.mask() {
                walk.mask(inner, ts, layer);
            }
        });
    }

    fn filter(&mut self, filter: &filter::Filter, ts: Transform) {
        let region = self.area(filter.rect().transform(ts).map(|r| r.to_rect()));
        let (sx, sy) = ts.get_scale();
        let mut results = 0.0;

        for primitive in filter.primitives() {
            self.work += region * weight(primitive.kind(), sx, sy);
            if let filter::Kind::Image(image) = primitive.kind() {
                self.nodes(image.root(), ts);
            }
            // resvg keeps every primitive's result until the filter finishes.
            results += region;
            self.live += region;
            self.peak = self.peak.max(self.live);
        }
        self.live -= results;
    }

    /// Records how far `rect`, drawn with `ts` and grown by `margin` pixels,
    /// reaches from the canvas's origin. A rect that doesn't transform to a
    /// finite one reaches infinitely far.
    fn reach(&mut self, rect: Rect, ts: Transform, margin: f32) {
        let reach = rect.transform(ts).map_or(f64::INFINITY, |r| {
            let far = r
                .left()
                .abs()
                .max(r.top().abs())
                .max(r.right().abs())
                .max(r.bottom().abs());
            f64::from(far) + f64::from(margin)
        });
        self.extent = self.extent.max(reach);
    }

    fn path(&mut self, path: &usvg::Path, ts: Transform) {
        let (sx, sy) = ts.get_scale();
        let stroke = path.stroke().map_or(0.0, |s| s.width().get() * sx.max(sy));
        self.reach(path.data().bounds(), ts, stroke);
        if path.stroke().is_some() {
            self.work += STROKED_CURVE_PER_PX * curve_length(path.data(), ts);
        }
        self.work += PER_NODE + self.area(path.bounding_box().transform(ts));
        let paints = [
            path.fill().map(|f| f.paint()),
            path.stroke().map(|s| s.paint()),
        ];

        for paint in paints.into_iter().flatten() {
            if let Paint::Pattern(pattern) = paint {
                let (sx, sy) = ts.pre_concat(pattern.transform()).get_scale();
                let rect = pattern.rect();
                let tile = f64::from(rect.width() * sx) * f64::from(rect.height() * sy);
                self.alloc(tile, |walk| {
                    walk.work += tile;
                    walk.nodes(pattern.root(), Transform::from_scale(sx, sy));
                });
            }
        }
    }

    fn image(&mut self, image: &usvg::Image, ts: Transform) {
        self.reach(image.bounding_box(), ts, 0.0);
        self.work += PER_NODE;
        let drawn = self.area(image.bounding_box().transform(ts));

        match image.kind() {
            ImageKind::SVG(tree) => {
                let fit = Transform::from_scale(
                    image.size().width() / tree.size().width(),
                    image.size().height() / tree.size().height(),
                );
                // resvg renders a nested SVG into its own canvas-sized pixmap.
                self.alloc(self.canvas, |walk| {
                    walk.work += walk.canvas;
                    walk.nodes(tree.root(), ts.pre_concat(fit));
                });
            }
            ImageKind::PNG(data)
            | ImageKind::JPEG(data)
            | ImageKind::GIF(data)
            | ImageKind::WEBP(data) => {
                let decoded = imagesize::blob_size(data).map_or(0, |size| {
                    (size.width as u64).saturating_mul(size.height as u64)
                });
                self.images += 1;
                self.image_pixels = self.image_pixels.saturating_add(decoded);
                // resvg decodes the image on every draw, then draws it.
                self.alloc(decoded as f64, |walk| walk.work += decoded as f64 + drawn);
            }
        }
    }
}

/// The length on the canvas of the control polygons of a path's curves.
fn curve_length(path: &resvg::tiny_skia::Path, ts: Transform) -> f64 {
    let length = |points: &[Point]| {
        let mut mapped = points.to_vec();
        ts.map_points(&mut mapped);
        mapped
            .windows(2)
            .map(|pair| f64::from(pair[0].distance(pair[1])))
            .sum::<f64>()
    };
    let mut last = Point::zero();
    let mut total = 0.0;
    for segment in path.segments() {
        match segment {
            PathSegment::MoveTo(point) | PathSegment::LineTo(point) => last = point,
            PathSegment::QuadTo(control, point) => {
                total += length(&[last, control, point]);
                last = point;
            }
            PathSegment::CubicTo(first, second, point) => {
                total += length(&[last, first, second, point]);
                last = point;
            }
            PathSegment::Close => {}
        }
    }
    total
}

/// How much slower than compositing a plain layer each primitive runs, per
/// pixel of the filter region. Morphology visits its whole kernel for every
/// pixel, and its radius scales with the render.
fn weight(kind: &filter::Kind, sx: f32, sy: f32) -> f64 {
    match kind {
        // Measured on x86 servers, where blur runs 20 to 30 times slower
        // per pixel than compositing a layer. Apple silicon blurs faster.
        filter::Kind::GaussianBlur(_) => 20.0,
        filter::Kind::DropShadow(_) => 22.0,
        filter::Kind::Morphology(m) => {
            let columns = 2.0 * f64::from(m.radius_x().get() * sx) + 1.0;
            let rows = 2.0 * f64::from(m.radius_y().get() * sy) + 1.0;
            columns * rows
        }
        filter::Kind::ConvolveMatrix(c) => {
            f64::from(c.matrix().columns()) * f64::from(c.matrix().rows())
        }
        filter::Kind::DiffuseLighting(_) | filter::Kind::SpecularLighting(_) => 6.0,
        filter::Kind::Turbulence(t) => 4.0 * f64::from(t.num_octaves()),
        filter::Kind::DisplacementMap(_) => 2.0,
        _ => 1.0,
    }
}
