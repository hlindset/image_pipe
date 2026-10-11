// Not referenced yet; keeps resvg in the build so the precompiled matrix and
// the version below are exercised before rendering lands.
use resvg as _;

/// The NIF crate version and the resvg version it was built with.
#[rustler::nif]
fn versions() -> (&'static str, &'static str) {
    (env!("CARGO_PKG_VERSION"), env!("RESVG_VERSION"))
}

rustler::init!("Elixir.ImagePipe.SVG.Native");
