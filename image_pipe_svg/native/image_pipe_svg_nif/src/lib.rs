mod cost;
mod entities;
mod fonts;
mod parse;
#[cfg(test)]
mod prescan_tests;
mod render;

use std::sync::Arc;

use resvg::usvg;
use rustler::{Binary, Env, NifResult, NifTaggedEnum, OwnedBinary, Resource, ResourceArc};

// Neither resource is mutated after it's built, so a panic can't leave one
// half-updated. Font data sits behind `dyn AsRef<[u8]>`, which isn't
// `RefUnwindSafe` by itself.
struct Fonts(Arc<usvg::fontdb::Database>);

impl std::panic::RefUnwindSafe for Fonts {}

#[rustler::resource_impl]
impl Resource for Fonts {}

struct Document(usvg::Tree);

impl std::panic::RefUnwindSafe for Document {}

#[rustler::resource_impl]
impl Resource for Document {}

/// A parsed document and its intrinsic width and height.
type Parsed = (ResourceArc<Document>, f32, f32);

#[derive(NifTaggedEnum)]
enum ParseError {
    Parse(String),
    TooManyElements(u64),
    EntityExpansion(u64),
    TooMuchText(u64),
    ImageTooLarge(u64),
    NestingTooDeep,
}

impl From<parse::Error> for ParseError {
    fn from(error: parse::Error) -> Self {
        match error {
            parse::Error::Parse(message) => ParseError::Parse(message),
            parse::Error::TooManyElements(count) => ParseError::TooManyElements(count),
            parse::Error::EntityExpansion(size) => ParseError::EntityExpansion(size),
            parse::Error::TooMuchText(bytes) => ParseError::TooMuchText(bytes),
            parse::Error::ImageTooLarge(pixels) => ParseError::ImageTooLarge(pixels),
            parse::Error::NestingTooDeep => ParseError::NestingTooDeep,
        }
    }
}

/// Stack for parsing, cost, and rendering. usvg allows 1024 nested elements,
/// and nested SVG images repeat that, while each level recurses in usvg, the
/// cost walk, and resvg. A dirty scheduler's stack overflows at a few hundred
/// levels and takes the VM down. Only the pages used are committed.
const STACK_BYTES: usize = 64 * 1024 * 1024;

/// Runs `work` on a thread with a stack deep enough for any SVG usvg accepts.
fn with_stack<T: Send>(work: impl FnOnce() -> T + Send) -> NifResult<T> {
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .stack_size(STACK_BYTES)
            .spawn_scoped(scope, work)
            .map_err(|_| rustler::Error::RaiseAtom("thread_spawn_failed"))?
            .join()
            .map_err(|_| rustler::Error::RaiseAtom("panic"))
    })
}

/// The NIF crate version and the resvg version it was built with.
#[rustler::nif]
fn versions() -> (&'static str, &'static str) {
    (env!("CARGO_PKG_VERSION"), env!("RESVG_VERSION"))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn load_fonts(
    files: Vec<(String, Binary)>,
    fallback: Option<String>,
) -> Result<ResourceArc<Fonts>, String> {
    let files = files
        .into_iter()
        .map(|(name, data)| (name, data.as_slice().to_vec()))
        .collect();
    let db = fonts::load(files, fallback)?;
    Ok(ResourceArc::new(Fonts(Arc::new(db))))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn parse(
    data: Binary,
    fonts: ResourceArc<Fonts>,
    limits: (u64, u64, u64, u64, u64),
) -> NifResult<Result<Parsed, ParseError>> {
    let (max_elements, max_image_pixels, max_entity_expansion, max_text_per_element, max_text) =
        limits;
    let limits = parse::Limits {
        max_elements,
        max_image_pixels,
        max_entity_expansion,
        max_text_per_element,
        max_text,
    };
    let data = data.as_slice();
    let fontdb = fonts.0.clone();
    let parsed = with_stack(move || parse::parse(data, fontdb, &limits))?;

    Ok(parsed.map_err(ParseError::from).map(|tree| {
        let size = tree.size();
        (
            ResourceArc::new(Document(tree)),
            size.width(),
            size.height(),
        )
    }))
}

#[rustler::nif(schedule = "DirtyCpu")]
fn cost(
    document: ResourceArc<Document>,
    width: u32,
    height: u32,
) -> NifResult<(u64, u64, u64, u64)> {
    let tree = &document.0;
    let cost = with_stack(|| cost::estimate(tree, width, height))?;
    Ok((cost.work, cost.peak, cost.images, cost.image_pixels))
}

/// Drawn geometry must stay this close to the canvas, in pixels. tiny-skia
/// turns paths into fixed-point edges without the clipping Skia does first,
/// so geometry much further away overflows them. That panics inside a
/// destructor, which aborts the VM instead of unwinding. Skia keeps clipped
/// paths within the same range.
const MAX_EXTENT: f64 = 32767.0;

/// Renders the document, or returns how far its geometry reaches when that's
/// past `MAX_EXTENT`.
#[rustler::nif(schedule = "DirtyCpu")]
fn render<'a>(
    env: Env<'a>,
    document: ResourceArc<Document>,
    width: u32,
    height: u32,
) -> NifResult<Result<Binary<'a>, u64>> {
    let tree = &document.0;
    let extent = with_stack(|| cost::estimate(tree, width, height).extent)?;
    if extent > MAX_EXTENT {
        return Ok(Err(extent.min(u64::MAX as f64) as u64));
    }

    let length = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .ok_or(rustler::Error::BadArg)?;
    let mut binary = OwnedBinary::new(length).ok_or(rustler::Error::RaiseAtom("enomem"))?;
    let pixels = binary.as_mut_slice();
    pixels.fill(0);
    with_stack(|| render::render(tree, width, height, pixels))?;
    Ok(Ok(binary.release(env)))
}

rustler::init!("Elixir.ImagePipe.SVG.Native");
