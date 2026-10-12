#![no_main]

#[path = "common.rs"]
mod common;

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| common::parse_and_render(data));
