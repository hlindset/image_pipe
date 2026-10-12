use resvg::tiny_skia::{PixmapMut, Transform};
use resvg::usvg;

/// Renders `tree` scaled to `width` × `height` into `pixels`, which must hold
/// `width * height * 4` zeroed bytes, leaving straight-alpha RGBA.
///
/// Drawing into the caller's buffer means the pixels are never copied after
/// rendering. tiny-skia draws premultiplied, so alpha is divided out in place.
pub fn render(tree: &usvg::Tree, width: u32, height: u32, pixels: &mut [u8]) {
    let size = tree.size();
    let ts = Transform::from_scale(width as f32 / size.width(), height as f32 / size.height());
    let mut pixmap = PixmapMut::from_bytes(pixels, width, height).expect("buffer fits the size");
    resvg::render(tree, ts, &mut pixmap);
    unpremultiply(pixels);
}

fn unpremultiply(pixels: &mut [u8]) {
    for pixel in pixels.as_chunks_mut::<4>().0 {
        let alpha = u32::from(pixel[3]);
        if alpha == 0 || alpha == 255 {
            continue;
        }
        for channel in &mut pixel[..3] {
            *channel = ((u32::from(*channel) * 255 + alpha / 2) / alpha).min(255) as u8;
        }
    }
}
