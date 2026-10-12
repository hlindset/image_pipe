// Each target uses part of this module.
#![allow(dead_code)]

//! What every target shares: the limits ImagePipe passes by default, an empty
//! font database, and a stack as large as the NIF's.

use std::sync::{Arc, OnceLock};

use image_pipe_svg_nif_fuzz::cost::estimate;
use image_pipe_svg_nif_fuzz::parse::{Limits, parse};
use image_pipe_svg_nif_fuzz::render::render;
use resvg::usvg::fontdb::Database;

pub const LIMITS: Limits = Limits {
    max_elements: 200_000,
    max_image_pixels: 40_000_000,
    max_entity_expansion: 1_000_000,
    max_text_per_element: 10_000,
    max_text: 1_000_000,
};

/// ImagePipe's default render budget, and the reach the render NIF allows.
const MAX_WORK: u64 = 100_000_000;
const MAX_PEAK: u64 = 160_000_000;
const MAX_EXTENT: f64 = 32767.0;

pub fn fonts() -> Arc<Database> {
    static FONTS: OnceLock<Arc<Database>> = OnceLock::new();
    FONTS.get_or_init(|| Arc::new(Database::new())).clone()
}

/// Writes `data` to the file `FUZZ_LAST_INPUT` names, if set. libFuzzer
/// can't save the input when the stack overflows on another thread, so this
/// keeps the input that was running.
pub fn record(data: &[u8]) {
    if let Some(path) = std::env::var_os("FUZZ_LAST_INPUT") {
        let _ = std::fs::write(path, data);
    }
}

/// Runs `work` on a 64 MB stack, as the NIF does. A panic propagates and a
/// stack overflow aborts, so libFuzzer reports both.
pub fn on_stack<T: Send>(work: impl FnOnce() -> T + Send) -> T {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .stack_size(64 * 1024 * 1024)
            .spawn_scoped(scope, work)
            .unwrap()
            .join()
            .unwrap()
    })
}

/// Parses, estimates, and renders at 64×64 when within the budget and reach,
/// as a request would.
pub fn parse_and_render(data: &[u8]) {
    record(data);
    on_stack(|| {
        let Ok(tree) = parse(data, fonts(), &LIMITS) else {
            return;
        };
        let cost = estimate(&tree, 64, 64);
        if cost.work <= MAX_WORK && cost.peak <= MAX_PEAK && cost.extent <= MAX_EXTENT {
            let mut pixels = vec![0u8; 64 * 64 * 4];
            render(&tree, 64, 64, &mut pixels);
        }
    })
}
