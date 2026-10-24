mod cost;
mod entities;
mod parse;
mod render;
use std::sync::Arc;
use resvg::usvg;
fn main() {
    let path = std::env::args().nth(1).unwrap();
    let w: u32 = std::env::args().nth(2).map(|s| s.parse().unwrap()).unwrap_or(256);
    let data = std::fs::read(path).unwrap();
    let limits = parse::Limits { max_elements: 200_000, max_image_pixels: 40_000_000, max_entity_expansion: 1_000_000, max_text_per_element: 10_000, max_text: 1_000_000 };
    let db = Arc::new(usvg::fontdb::Database::new());
    let tree = match parse::parse(&data, db, &limits) { Ok(t) => t, Err(e) => { println!("parse err {:?}", e); return; } };
    let c = cost::estimate(&tree, w, w);
    println!("work {} peak {} extent {}", c.work, c.peak, c.extent);
    if c.extent > 32767.0 { println!("refused"); return; }
    let mut px = vec![0u8; (w*w*4) as usize];
    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| render::render(&tree, w, w, &mut px)));
    println!("render result ok={} nonzero={}", r.is_ok(), px.iter().filter(|b| **b != 0).count());
}
