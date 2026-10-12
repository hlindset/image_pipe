use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex};

use resvg::usvg::roxmltree::{self, Node, NodeId};
use resvg::usvg::{self, ImageHrefResolver, ImageKind, Options};

use crate::entities;

/// Nested `data:image/svg+xml` images may go this many levels deep.
const MAX_NESTING: u32 = 2;

/// Elements may nest this deep, as usvg allows. roxmltree recurses once per
/// level with no limit of its own, so deeper nesting would overflow the stack.
const MAX_DEPTH: usize = 1024;

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

impl Limits {
    /// What's left of the limits shared by embedded SVGs after `used`.
    fn remaining(&self, used: &Usage) -> Limits {
        Limits {
            max_elements: self.max_elements.saturating_sub(used.elements),
            max_entity_expansion: self.max_entity_expansion.saturating_sub(used.expansion),
            max_text: self.max_text.saturating_sub(used.text),
            ..*self
        }
    }
}

/// What one document's parse used of the limits.
#[derive(Default, Clone, Copy)]
struct Usage {
    elements: u64,
    expansion: u64,
    text: u64,
}

impl Usage {
    fn add(&mut self, other: Usage) {
        self.elements = self.elements.saturating_add(other.elements);
        self.expansion = self.expansion.saturating_add(other.expansion);
        self.text = self.text.saturating_add(other.text);
    }
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
    let (doc, usage) = checked_document(text, limits)?;

    let violation = Arc::new(Mutex::new(None));
    let options = options(fontdb, *limits, usage, violation.clone());
    let tree = usvg::Tree::from_xmltree(&doc, &options);

    if let Some(error) = violation.lock().unwrap().take() {
        return Err(error);
    }

    tree.map_err(|error| Error::Parse(error.to_string()))
}

/// Parses `text` with roxmltree once its entities and `<use>` expansion are
/// known to stay within `limits`, and returns what it used of them.
fn checked_document<'input>(
    text: &'input str,
    limits: &Limits,
) -> Result<(roxmltree::Document<'input>, Usage), Error> {
    let entities = entities::scan(text);
    if entities.markup {
        return Err(Error::Parse(
            "entities containing markup aren't supported".into(),
        ));
    }
    let expansion = entities.expansion;
    if expansion > limits.max_entity_expansion {
        return Err(Error::EntityExpansion(expansion));
    }
    check_depth(text)?;

    let xml_opt = roxmltree::ParsingOptions {
        allow_dtd: true,
        nodes_limit: u32::try_from(limits.max_elements.saturating_mul(4)).unwrap_or(u32::MAX),
        ..Default::default()
    };
    let doc = roxmltree::Document::parse_with_options(text, xml_opt)
        .map_err(|error| Error::Parse(error.to_string()))?;

    let expanded = expand(&doc);
    if expanded.elements > limits.max_elements {
        return Err(Error::TooManyElements(expanded.elements));
    }
    if expanded.largest_text > limits.max_text_per_element {
        return Err(Error::TooMuchText(expanded.largest_text));
    }
    if expanded.text > limits.max_text {
        return Err(Error::TooMuchText(expanded.text));
    }
    let usage = Usage {
        elements: expanded.elements,
        expansion,
        text: expanded.text,
    };
    Ok((doc, usage))
}

fn options(
    fontdb: Arc<usvg::fontdb::Database>,
    limits: Limits,
    outer: Usage,
    violation: Arc<Mutex<Option<Error>>>,
) -> Options<'static> {
    let depth = Arc::new(AtomicU32::new(0));
    // Embedded SVGs share the outer document's limits, since usvg parses an
    // image again for each `<use>` copy of it.
    let nested = Arc::new(Mutex::new(outer));

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
                // usvg parses the embedded SVG itself, so check it first
                // against what's left of the limits. One that doesn't parse
                // renders as nothing.
                let Ok(text) = std::str::from_utf8(&data) else {
                    return None;
                };
                let mut used = nested.lock().unwrap();
                match checked_document(text, &limits.remaining(&used)) {
                    Ok((_, usage)) => used.add(usage),
                    Err(Error::EntityExpansion(n)) => {
                        record(
                            &violation,
                            Error::EntityExpansion(n.saturating_add(used.expansion)),
                        );
                        return None;
                    }
                    Err(Error::TooManyElements(n)) => {
                        record(
                            &violation,
                            Error::TooManyElements(n.saturating_add(used.elements)),
                        );
                        return None;
                    }
                    Err(Error::TooMuchText(n)) if n > limits.max_text_per_element => {
                        record(&violation, Error::TooMuchText(n));
                        return None;
                    }
                    Err(Error::TooMuchText(n)) => {
                        record(&violation, Error::TooMuchText(n.saturating_add(used.text)));
                        return None;
                    }
                    Err(_) => return None,
                }
                drop(used);
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

/// Fails when elements nest deeper than `MAX_DEPTH`, by reading the tags
/// alone. Comments, CDATA, processing instructions, the DOCTYPE, and quoted
/// attribute values are skipped, so markup inside them doesn't count. Each
/// byte is read once.
fn check_depth(text: &str) -> Result<(), Error> {
    let bytes = text.as_bytes();
    let skip_to = |from: usize, end: &str| {
        text[from..]
            .find(end)
            .map_or(bytes.len(), |at| from + at + end.len())
    };
    let mut depth = 0usize;
    let mut i = 0;

    while let Some(at) = bytes[i..].iter().position(|&b| b == b'<') {
        i += at;
        let rest = &text[i..];
        i = if rest.starts_with("<!--") {
            skip_to(i + 4, "-->")
        } else if rest.starts_with("<![CDATA[") {
            skip_to(i + 9, "]]>")
        } else if rest.starts_with("<?") {
            skip_to(i + 2, "?>")
        } else if rest.starts_with("<!") {
            declaration_end(text, i + 2)
        } else if rest.starts_with("</") {
            depth = depth.saturating_sub(1);
            tag_end(bytes, i + 2).0
        } else {
            let (end, empty) = tag_end(bytes, i + 1);
            if !empty {
                depth += 1;
                if depth > MAX_DEPTH {
                    return Err(Error::Parse(format!(
                        "elements nest deeper than {MAX_DEPTH} levels"
                    )));
                }
            }
            end
        };
    }
    Ok(())
}

/// Where a tag that starts at `i` ends, and whether it's an empty-element tag.
fn tag_end(bytes: &[u8], mut i: usize) -> (usize, bool) {
    let mut last = 0u8;
    while let Some(&byte) = bytes.get(i) {
        match byte {
            b'>' => return (i + 1, last == b'/'),
            b'"' | b'\'' => i = quote_end(bytes, i),
            _ => {
                if !byte.is_ascii_whitespace() {
                    last = byte;
                }
                i += 1;
            }
        }
    }
    (bytes.len(), false)
}

/// Where a `<!...>` declaration such as the DOCTYPE ends, past its internal
/// subset and any comments, processing instructions, and quoted literals.
fn declaration_end(text: &str, mut i: usize) -> usize {
    let bytes = text.as_bytes();
    let mut brackets = 0usize;
    while let Some(&byte) = bytes.get(i) {
        let rest = &text[i..];
        if rest.starts_with("<!--") {
            i = text[i + 4..]
                .find("-->")
                .map_or(bytes.len(), |at| i + 4 + at + 3);
            continue;
        }
        if rest.starts_with("<?") {
            i = text[i + 2..]
                .find("?>")
                .map_or(bytes.len(), |at| i + 2 + at + 2);
            continue;
        }
        match byte {
            b'"' | b'\'' => {
                i = quote_end(bytes, i);
                continue;
            }
            b'[' => brackets += 1,
            b']' => brackets = brackets.saturating_sub(1),
            b'>' if brackets == 0 => return i + 1,
            _ => {}
        }
        i += 1;
    }
    bytes.len()
}

/// The index just past the quote that closes the one at `i`.
fn quote_end(bytes: &[u8], i: usize) -> usize {
    let quote = bytes[i];
    bytes[i + 1..]
        .iter()
        .position(|&b| b == quote)
        .map_or(bytes.len(), |at| i + 1 + at + 1)
}

/// What usvg will build from a document once it copies content in place:
/// each `<use>` or `feImage` target where it's used, each marker at each vertex of the
/// shapes that use it, and each clip path, mask, or pattern sized to the
/// bounding box of the element that uses it, and each filter holding an
/// `feImage` of an element, for every element that uses them. The counts err
/// high: every number in a shape counts as a vertex, and a reference from a
/// stylesheet counts as made by every element.
struct Expanded {
    elements: u64,
    /// Bytes of text inside `<text>` elements, counting every copy.
    text: u64,
    /// The most text in any one `<text>` element.
    largest_text: u64,
}

fn expand(doc: &roxmltree::Document) -> Expanded {
    let ids: HashMap<&str, Node> = doc
        .descendants()
        .filter_map(|node| node.attribute("id").map(|id| (id, node)))
        .collect();
    let copied: HashSet<&str> = ids
        .iter()
        .filter(|(_, node)| copied_per_use(node))
        .map(|(id, _)| *id)
        .collect();

    // References from stylesheets, which may apply to any element.
    let mut styled = Vec::new();
    let mut styled_markers = Vec::new();
    for style in doc.descendants().filter(|n| n.tag_name().name() == "style") {
        for id in style.text().map(url_ids).into_iter().flatten() {
            match ids.get(id) {
                Some(node) if node.tag_name().name() == "marker" => styled_markers.push(id),
                Some(_) if copied.contains(id) => styled.push(id),
                _ => {}
            }
        }
    }

    let mut walk = Walk {
        ids,
        copied,
        styled,
        styled_markers,
        memo: HashMap::new(),
        largest_text: 0,
    };
    let (elements, text) = walk.node(doc.root_element(), false, NO_MARKERS);
    Expanded {
        elements,
        text,
        largest_text: walk.largest_text,
    }
}

/// Whether usvg copies a definition's content for each element that uses it.
fn copied_per_use(node: &Node) -> bool {
    match node.tag_name().name() {
        "clipPath" => node.attribute("clipPathUnits") == Some("objectBoundingBox"),
        "mask" => node.attribute("maskContentUnits") == Some("objectBoundingBox"),
        "pattern" => node.attribute("patternContentUnits") == Some("objectBoundingBox"),
        "filter" => node
            .descendants()
            .filter(|n| n.tag_name().name() == "feImage")
            .any(|n| href(n).is_some_and(|href| href.starts_with('#'))),
        _ => false,
    }
}

/// The markers a shape draws at its start, middle vertices, and end.
type Markers<'a> = [Option<&'a str>; 3];
const NO_MARKERS: Markers = [None, None, None];

struct Walk<'a, 'input> {
    ids: HashMap<&'a str, Node<'a, 'input>>,
    copied: HashSet<&'a str>,
    styled: Vec<&'a str>,
    styled_markers: Vec<&'a str>,
    memo: HashMap<(NodeId, bool, Markers<'a>), Option<(u64, u64)>>,
    largest_text: u64,
}

impl<'a, 'input> Walk<'a, 'input> {
    /// The elements and text bytes a node expands to. A reference cycle,
    /// which usvg skips, counts as empty.
    fn node(&mut self, node: Node<'a, 'input>, inside: bool, markers: Markers<'a>) -> (u64, u64) {
        if node.is_text() {
            let bytes = if inside {
                node.text().map_or(0, |t| t.len() as u64)
            } else {
                0
            };
            return (0, bytes);
        }
        if !node.is_element() {
            return (0, 0);
        }
        let key = (node.id(), inside, markers);
        match self.memo.get(&key) {
            Some(Some(counts)) => return *counts,
            Some(None) => return (0, 0),
            None => {}
        }
        self.memo.insert(key, None);

        let name = node.tag_name().name();
        let starts_text = !inside && name == "text";
        let inside = inside || starts_text;
        let markers = own_markers(node, markers);
        let mut total = (1u64, 0u64);
        let add = |total: &mut (u64, u64), (elements, text): (u64, u64), times: u64| {
            total.0 = total.0.saturating_add(elements.saturating_mul(times));
            total.1 = total.1.saturating_add(text.saturating_mul(times));
        };

        for child in node.children() {
            let counts = self.node(child, inside, markers);
            add(&mut total, counts, 1);
        }
        if matches!(name, "use" | "feImage")
            && let Some(target) = href(node)
                .and_then(|href| href.strip_prefix('#'))
                .and_then(|id| self.ids.get(id).copied())
        {
            let counts = self.node(target, inside, markers);
            add(&mut total, counts, 1);
        }

        let referenced: Vec<&str> = ["clip-path", "mask", "filter", "fill", "stroke"]
            .into_iter()
            .filter_map(|name| property(node, name).and_then(url_id))
            .filter(|id| self.copied.contains(id))
            .chain(self.styled.iter().copied())
            .collect();
        for id in referenced {
            if let Some(target) = self.ids.get(id).copied() {
                let counts = self.node(target, false, NO_MARKERS);
                add(&mut total, counts, 1);
            }
        }

        if matches!(name, "path" | "line" | "polyline" | "polygon") {
            let vertices = vertices(node);
            let drawn: Vec<(&str, u64)> = markers
                .iter()
                .zip([1, vertices, 1])
                .filter_map(|(id, times)| id.map(|id| (id, times)))
                .chain(
                    self.styled_markers
                        .iter()
                        .map(|id| (*id, vertices.saturating_add(2))),
                )
                .collect();
            for (id, times) in drawn {
                if let Some(target) = self.ids.get(id).copied() {
                    let counts = self.node(target, false, NO_MARKERS);
                    add(&mut total, counts, times);
                }
            }
        }

        if starts_text {
            self.largest_text = self.largest_text.max(total.1);
        }
        self.memo.insert(key, Some(total));
        total
    }
}

/// The markers in effect on `node`: its own marker properties, or those it
/// inherits.
fn own_markers<'a>(node: Node<'a, '_>, inherited: Markers<'a>) -> Markers<'a> {
    let mut markers = inherited;
    if let Some(all) = property(node, "marker") {
        markers = [url_id(all); 3];
    }
    for (slot, name) in ["marker-start", "marker-mid", "marker-end"]
        .into_iter()
        .enumerate()
    {
        if let Some(value) = property(node, name) {
            markers[slot] = url_id(value);
        }
    }
    markers
}

/// A presentation property set in the `style` attribute, which wins, or as
/// an attribute.
fn property<'a>(node: Node<'a, '_>, name: &str) -> Option<&'a str> {
    let styled = node.attribute("style").and_then(|style| {
        style.split(';').find_map(|declaration| {
            let (key, value) = declaration.split_once(':')?;
            (key.trim() == name).then(|| value.trim())
        })
    });
    styled.or_else(|| node.attribute(name))
}

/// The id in a `url(#id)` reference, or `None` for anything else.
fn url_id(value: &str) -> Option<&str> {
    let inner = value.trim().strip_prefix("url(")?;
    let inner = &inner[..inner.find(')')?];
    inner.trim().trim_matches(['"', '\'']).strip_prefix('#')
}

/// Every id referenced as `url(#id)` in a stylesheet.
fn url_ids(text: &str) -> impl Iterator<Item = &str> {
    text.match_indices("url(")
        .filter_map(|(i, _)| url_id(&text[i..]))
}

fn href<'a>(node: Node<'a, '_>) -> Option<&'a str> {
    node.attribute((XLINK_NS, "href"))
        .or_else(|| node.attribute("href"))
}

/// An upper bound on a shape's vertices: every run of digits in its path data
/// or points counts as a number, and every path command as one more.
fn vertices(node: Node) -> u64 {
    let data = match node.tag_name().name() {
        "line" => return 2,
        "path" => node.attribute("d"),
        _ => node.attribute("points"),
    };
    let Some(data) = data else { return 0 };
    let mut count = 0u64;
    let mut in_digits = false;
    for byte in data.bytes() {
        let digit = byte.is_ascii_digit();
        if digit && !in_digits {
            count += 1;
        }
        if byte.is_ascii_alphabetic() && byte != b'e' && byte != b'E' {
            count += 1;
        }
        in_digits = digit;
    }
    count
}
