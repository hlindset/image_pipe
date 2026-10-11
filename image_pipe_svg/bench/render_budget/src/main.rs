use resvg::{tiny_skia, usvg};
use std::time::Instant;

fn count(g: &usvg::Group, n: &mut usize, imgs: &mut usize) {
    for c in g.children() {
        *n += 1;
        if let usvg::Node::Image(_) = c { *imgs += 1; }
        c.subroots(|s| count(s, n, imgs));
        if let usvg::Node::Group(g) = c { count(g, n, imgs); }
    }
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let path = &args[1];
    let width: f32 = args[2].parse().unwrap();
    let data = std::fs::read(path).unwrap();

    let mut opt = usvg::Options::default();
    opt.default_size = usvg::Size::from_wh(300.0, 150.0).unwrap();
    opt.image_href_resolver.resolve_string = Box::new(|_, _| None);

    let t = Instant::now();
    let tree = match usvg::Tree::from_data(&data, &opt) {
        Ok(t) => t,
        Err(e) => { println!("bytes={} parse_err={:?} parse_ms={:.1}", data.len(), e, t.elapsed().as_secs_f64()*1e3); return; }
    };
    let parse_ms = t.elapsed().as_secs_f64() * 1e3;
    let (mut nodes, mut imgs) = (0, 0);
    let t = Instant::now();
    count(tree.root(), &mut nodes, &mut imgs);
    let walk_ms = t.elapsed().as_secs_f64() * 1e3;

    let size = tree.size();
    let scale = width / size.width();
    let (w, h) = ((size.width() * scale).ceil() as u32, (size.height() * scale).ceil() as u32);
    let mut pixmap = tiny_skia::Pixmap::new(w, h).unwrap();
    let t = Instant::now();
    resvg::render(&tree, tiny_skia::Transform::from_scale(scale, scale), &mut pixmap.as_mut());
    let render_ms = t.elapsed().as_secs_f64() * 1e3;
    println!("bytes={} intrinsic={}x{} out={}x{} nodes={} images={} parse_ms={:.1} walk_ms={:.1} render_ms={:.1}",
        data.len(), size.width(), size.height(), w, h, nodes, imgs, parse_ms, walk_ms, render_ms);
}
