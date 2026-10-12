//! The NIF's parsing, cost, and rendering modules, compiled from `../src`
//! without the rustler layer, whose `cdylib` can't link with libFuzzer's
//! coverage instrumentation.

#[path = "../../src/cost.rs"]
pub mod cost;
#[path = "../../src/entities.rs"]
pub mod entities;
#[path = "../../src/parse.rs"]
pub mod parse;
#[path = "../../src/render.rs"]
pub mod render;
