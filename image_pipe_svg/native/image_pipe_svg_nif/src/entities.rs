//! An upper bound on how much text an SVG's entities expand to, found in one
//! pass before parsing.
//!
//! roxmltree limits each top-level entity reference to 255 nested ones but not
//! the total, so a few kilobytes of declarations and references can expand to
//! hundreds of megabytes during parsing. Rejecting such a document before the
//! parse is the only way to avoid allocating that memory.

use std::collections::HashMap;

/// Entity references nest at most this deep. roxmltree stops at 10, so a
/// deeper chain fails to parse anyway, and counting it as unbounded keeps the
/// walk's recursion shallow.
const MAX_DEPTH: u32 = 10;

pub struct Scan {
    /// The total characters the document's entity references expand to.
    pub expansion: u64,
    /// Whether an entity's value holds markup. Elements inside entities would
    /// nest past the depth check, which reads only the document's own tags.
    pub markup: bool,
}

/// Counts each reference once per occurrence. Declarations and references
/// are found anywhere in the text, without parsing the DTD, so comments,
/// quoted literals, or processing instructions can't hide them. References
/// inside declarations or comments count too, and a name declared more than
/// once counts its largest value, so the bound only errs high. The scan is
/// linear in the length of the text.
pub fn scan(text: &str) -> Scan {
    let entities = declarations(text);
    let markup = entities.values().flatten().any(|value| value.contains('<'));
    if entities.is_empty() {
        return Scan {
            expansion: 0,
            markup,
        };
    }

    let mut sizes = HashMap::new();
    let expansion = references(text, &entities)
        .map(|name| size(name, &entities, &mut sizes, 0))
        .fold(0u64, u64::saturating_add);
    Scan { expansion, markup }
}

/// Every quoted `<!ENTITY>` value in the text, by name. roxmltree registers
/// general and parameter entities alike.
fn declarations(text: &str) -> HashMap<&str, Vec<&str>> {
    let mut entities = HashMap::new();
    for (i, _) in text.match_indices("<!ENTITY") {
        entity(text, i + 8, &mut entities);
    }
    entities
}

/// Records one `<!ENTITY [%] name "value">` starting after `<!ENTITY`. A value
/// whose quote never closes has no value.
fn entity<'a>(text: &'a str, mut i: usize, entities: &mut HashMap<&'a str, Vec<&'a str>>) {
    let bytes = text.as_bytes();
    let skip_spaces = |mut i: usize| {
        while bytes.get(i).is_some_and(u8::is_ascii_whitespace) {
            i += 1;
        }
        i
    };

    i = skip_spaces(i);
    if bytes.get(i) == Some(&b'%') {
        i = skip_spaces(i + 1);
    }
    let start = i;
    while bytes.get(i).copied().is_some_and(name_byte) {
        i += 1;
    }
    let name = &text[start..i];
    i = skip_spaces(i);

    if let Some(&quote) = bytes.get(i)
        && (quote == b'"' || quote == b'\'')
        && let Some(end) = text[i + 1..].find(quote as char)
    {
        let value = &text[i + 1..i + 1 + end];
        entities.entry(name).or_default().push(value);
    }
}

/// Whether `byte` can be part of an XML name. Bytes of multibyte characters
/// count, which errs toward longer names.
fn name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'-' | b'_' | b':') || byte >= 0x80
}

/// Names of declared entities referenced as `&name;` in `text`. Each name is
/// read up to the first byte that can't be in one, so the scan stays linear.
fn references<'k>(
    text: &str,
    entities: &HashMap<&'k str, Vec<&'k str>>,
) -> impl Iterator<Item = &'k str> {
    let bytes = text.as_bytes();
    text.match_indices('&').filter_map(move |(i, _)| {
        let start = i + 1;
        let mut end = start;
        while bytes.get(end).copied().is_some_and(name_byte) {
            end += 1;
        }
        if end == start || bytes.get(end) != Some(&b';') {
            return None;
        }
        entities
            .get_key_value(&text[start..end])
            .map(|(name, _)| *name)
    })
}

/// An entity's expanded size: its largest value plus what each reference in
/// that value expands to. A reference cycle, which roxmltree rejects anyway,
/// or a chain deeper than roxmltree allows, counts as unbounded.
fn size<'a>(
    name: &'a str,
    entities: &HashMap<&'a str, Vec<&'a str>>,
    sizes: &mut HashMap<&'a str, Option<u64>>,
    depth: u32,
) -> u64 {
    match sizes.get(name) {
        Some(Some(size)) => return *size,
        Some(None) => return u64::MAX,
        None => {}
    }
    if depth > MAX_DEPTH {
        return u64::MAX;
    }
    sizes.insert(name, None);

    let total = entities[name]
        .iter()
        .map(|value| {
            references(value, entities)
                .map(|reference| size(reference, entities, sizes, depth + 1))
                .fold(value.len() as u64, u64::saturating_add)
        })
        .max()
        .unwrap_or(0);

    sizes.insert(name, Some(total));
    total
}
