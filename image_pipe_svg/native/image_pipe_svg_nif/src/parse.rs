use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use resvg::usvg::roxmltree::{self, Node, NodeId};
use resvg::usvg::{self, ImageHrefResolver, ImageKind, Options};

use crate::entities;

/// Nested `data:image/svg+xml` images may go this many levels deep.
const MAX_NESTING: u32 = 2;

const XLINK_NS: &str = "http://www.w3.org/1999/xlink";

#[derive(Clone, Copy)]
pub struct Limits {
    /// Elements after expanding `<use>`, estimated before usvg expands them.
    pub max_elements: u64,
    /// Pixels of any one embedded raster image, read from its header.
    pub max_image_pixels: u64,
    /// Characters entity references expand to, estimated before parsing.
    pub max_entity_expansion: u64,
    /// Text bytes in any one `<text>` element. usvg lays text out while it
    /// parses, at a cost that grows with the square of one element's text.
    pub max_text_per_element: u64,
    /// Text bytes in all `<text>` elements, counting `<use>` copies.
    pub max_text: u64,
}

#[derive(Debug)]
pub enum Error {
    Parse(String),
    TooManyElements(u64),
    EntityExpansion(u64),
    TooMuchText(u64),
    ImageTooLarge(u64),
    NestingTooDeep,
}

/// Parses an SVG without reading files or opening connections.
///
/// External `href`s resolve to nothing. Embedded `data:` images resolve only
/// as PNG, JPEG, GIF, WebP, or SVG whose declared media type matches their
/// signature; anything else, including gzip-compressed SVG, renders as empty.
pub fn parse(
    data: &[u8],
    fontdb: Arc<usvg::fontdb::Database>,
    limits: &Limits,
) -> Result<usvg::Tree, Error> {
    let text = std::str::from_utf8(data).map_err(|_| Error::Parse("not UTF-8".into()))?;
    let doc = checked_document(text, limits)?;

    let violation = Arc::new(Mutex::new(None));
    let options = options(fontdb, *limits, violation.clone());
    let tree = usvg::Tree::from_xmltree(&doc, &options);

    if let Some(error) = violation.lock().unwrap().take() {
        return Err(error);
    }

    tree.map_err(|error| Error::Parse(error.to_string()))
}

/// Parses `text` with roxmltree once its entities and `<use>` expansion are
/// known to stay within `limits`.
fn checked_document<'input>(
    text: &'input str,
    limits: &Limits,
) -> Result<roxmltree::Document<'input>, Error> {
    let expansion = entities::expanded_size(text);
    if expansion > limits.max_entity_expansion {
        return Err(Error::EntityExpansion(expansion));
    }

    let xml_opt = roxmltree::ParsingOptions {
        allow_dtd: true,
        nodes_limit: u32::try_from(limits.max_elements.saturating_mul(4)).unwrap_or(u32::MAX),
        ..Default::default()
    };
    let doc = roxmltree::Document::parse_with_options(text, xml_opt)
        .map_err(|error| Error::Parse(error.to_string()))?;

    let elements = expanded_elements(&doc);
    if elements > limits.max_elements {
        return Err(Error::TooManyElements(elements));
    }

    let text = text_bytes(&doc);
    if text.largest > limits.max_text_per_element {
        return Err(Error::TooMuchText(text.largest));
    }
    if text.total > limits.max_text {
        return Err(Error::TooMuchText(text.total));
    }
    Ok(doc)
}

fn options(
    fontdb: Arc<usvg::fontdb::Database>,
    limits: Limits,
    violation: Arc<Mutex<Option<Error>>>,
) -> Options<'static> {
    let depth = Arc::new(AtomicU32::new(0));

    let resolve_data = move |mime: &str, data: Arc<Vec<u8>>, opts: &Options| {
        if data.starts_with(&[0x1f, 0x8b]) {
            return None;
        }

        let sniffed = imagesize::image_type(&data).ok();
        let kind = match (mime, sniffed) {
            ("image/png", Some(imagesize::ImageType::Png)) => ImageKind::PNG(data),
            ("image/jpeg" | "image/jpg", Some(imagesize::ImageType::Jpeg)) => ImageKind::JPEG(data),
            ("image/gif", Some(imagesize::ImageType::Gif)) => ImageKind::GIF(data),
            ("image/webp", Some(imagesize::ImageType::Webp)) => ImageKind::WEBP(data),
            ("image/svg+xml", None) => {
                if depth.load(Ordering::SeqCst) >= MAX_NESTING {
                    record(&violation, Error::NestingTooDeep);
                    return None;
                }
                // usvg parses the embedded SVG itself, so check it first with
                // the outer document's limits. One that doesn't parse renders
                // as nothing.
                match std::str::from_utf8(&data).map(|text| checked_document(text, &limits)) {
                    Ok(Ok(_)) => {}
                    Ok(Err(
                        error @ (Error::EntityExpansion(_)
                        | Error::TooManyElements(_)
                        | Error::TooMuchText(_)),
                    )) => {
                        record(&violation, error);
                        return None;
                    }
                    _ => return None,
                }
                depth.fetch_add(1, Ordering::SeqCst);
                let tree = usvg::Tree::from_data_nested(&data, opts);
                depth.fetch_sub(1, Ordering::SeqCst);
                return tree.ok().map(ImageKind::SVG);
            }
            _ => return None,
        };

        let size = imagesize::blob_size(kind_data(&kind)).ok()?;
        let pixels = (size.width as u64).saturating_mul(size.height as u64);
        if pixels > limits.max_image_pixels {
            record(&violation, Error::ImageTooLarge(pixels));
            return None;
        }
        Some(kind)
    };

    let mut options = Options {
        fontdb,
        ..Options::default()
    };
    options.image_href_resolver = ImageHrefResolver {
        resolve_data: Box::new(resolve_data),
        resolve_string: Box::new(|_, _| None),
    };
    options
}

fn kind_data(kind: &ImageKind) -> &[u8] {
    match kind {
        ImageKind::PNG(data)
        | ImageKind::JPEG(data)
        | ImageKind::GIF(data)
        | ImageKind::WEBP(data) => data,
        ImageKind::SVG(_) => &[],
    }
}

fn record(violation: &Mutex<Option<Error>>, error: Error) {
    violation.lock().unwrap().get_or_insert(error);
}

/// Counts elements as usvg will after copying each `<use>` target in place,
/// memoizing each referenced subtree. A reference cycle counts as empty,
/// since usvg skips it.
fn expanded_elements(doc: &roxmltree::Document) -> u64 {
    let ids: HashMap<&str, Node> = doc
        .descendants()
        .filter_map(|node| node.attribute("id").map(|id| (id, node)))
        .collect();
    let mut sizes = HashMap::new();
    size(doc.root_element(), &ids, &mut sizes)
}

fn size<'a, 'input>(
    node: Node<'a, 'input>,
    ids: &HashMap<&str, Node<'a, 'input>>,
    sizes: &mut HashMap<NodeId, Option<u64>>,
) -> u64 {
    match sizes.get(&node.id()) {
        Some(Some(size)) => return *size,
        Some(None) => return 0,
        None => {}
    }
    sizes.insert(node.id(), None);

    let mut total: u64 = 1;
    for child in node.children().filter(Node::is_element) {
        total = total.saturating_add(size(child, ids, sizes));
    }

    if node.tag_name().name() == "use" {
        let href = node
            .attribute((XLINK_NS, "href"))
            .or_else(|| node.attribute("href"));
        if let Some(target) = href
            .and_then(|href| href.strip_prefix('#'))
            .and_then(|id| ids.get(id))
        {
            total = total.saturating_add(size(*target, ids, sizes));
        }
    }

    sizes.insert(node.id(), Some(total));
    total
}

struct TextBytes {
    total: u64,
    largest: u64,
}

/// Counts the text usvg will lay out: bytes of text inside `<text>` elements,
/// with each `<use>` target counted where it's copied, and the most in any
/// one `<text>` element. Whitespace between other elements isn't laid out.
fn text_bytes(doc: &roxmltree::Document) -> TextBytes {
    let ids: HashMap<&str, Node> = doc
        .descendants()
        .filter_map(|node| node.attribute("id").map(|id| (id, node)))
        .collect();
    let mut walk = TextWalk {
        ids,
        memo: HashMap::new(),
        largest: 0,
    };
    let total = walk.bytes(doc.root_element(), false);
    TextBytes {
        total,
        largest: walk.largest,
    }
}

struct TextWalk<'a, 'input> {
    ids: HashMap<&'a str, Node<'a, 'input>>,
    memo: HashMap<(NodeId, bool), Option<u64>>,
    largest: u64,
}

impl<'a, 'input> TextWalk<'a, 'input> {
    fn bytes(&mut self, node: Node<'a, 'input>, inside: bool) -> u64 {
        if node.is_text() {
            return if inside {
                node.text().map_or(0, |t| t.len() as u64)
            } else {
                0
            };
        }
        match self.memo.get(&(node.id(), inside)) {
            Some(Some(bytes)) => return *bytes,
            // A reference cycle, which usvg skips.
            Some(None) => return 0,
            None => {}
        }
        self.memo.insert((node.id(), inside), None);

        let starts_text = !inside && node.tag_name().name() == "text";
        let inside = inside || starts_text;
        let mut total: u64 = 0;
        for child in node.children() {
            total = total.saturating_add(self.bytes(child, inside));
        }
        if node.tag_name().name() == "use" {
            let href = node
                .attribute((XLINK_NS, "href"))
                .or_else(|| node.attribute("href"));
            if let Some(target) = href
                .and_then(|href| href.strip_prefix('#'))
                .and_then(|id| self.ids.get(id).copied())
            {
                total = total.saturating_add(self.bytes(target, inside));
            }
        }

        if starts_text {
            self.largest = self.largest.max(total);
        }
        self.memo.insert((node.id(), inside), Some(total));
        total
    }
}
