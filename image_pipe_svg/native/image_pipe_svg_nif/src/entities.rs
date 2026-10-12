//! An upper bound on how much text an SVG's entities expand to, found in one
//! pass before parsing.
//!
//! roxmltree limits each top-level entity reference to 255 nested ones but not
//! the total, so a few kilobytes of declarations and references can expand to
//! hundreds of megabytes during parsing. Rejecting such a document before the
//! parse is the only way to avoid allocating that memory.

use std::collections::HashMap;

/// The total characters the document's entity references expand to, counting
/// each reference once per occurrence. Declarations and references are found
/// anywhere in the text, without parsing the DTD, so comments, quoted
/// literals, or processing instructions can't hide them. References inside
/// declarations or comments count too, and a name declared more than once
/// counts its largest value, so the bound only errs high.
pub fn expanded_size(text: &str) -> u64 {
    let entities = declarations(text);
    if entities.is_empty() {
        return 0;
    }

    let mut sizes = HashMap::new();
    references(text, &entities)
        .map(|name| size(name, &entities, &mut sizes))
        .fold(0u64, u64::saturating_add)
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

/// Records one `<!ENTITY [%] name "value">` starting after `<!ENTITY`.
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
    while bytes.get(i).is_some_and(|b| !b.is_ascii_whitespace()) {
        i += 1;
    }
    let name = &text[start..i];
    i = skip_spaces(i);

    match bytes.get(i) {
        Some(&quote) if quote == b'"' || quote == b'\'' => {
            let end = closing_quote(text, i);
            let value = &text[i + 1..end.saturating_sub(1).max(i + 1)];
            entities.entry(name).or_default().push(value);
        }
        _ => {}
    }
}

/// The index just past the quote that closes the one at `i`.
fn closing_quote(text: &str, i: usize) -> usize {
    let quote = text.as_bytes()[i] as char;
    text[i + 1..]
        .find(quote)
        .map_or(text.len(), |end| i + 1 + end + 1)
}

/// Names of declared entities referenced as `&name;` in `text`.
fn references<'k>(
    text: &str,
    entities: &HashMap<&'k str, Vec<&'k str>>,
) -> impl Iterator<Item = &'k str> {
    text.match_indices('&').filter_map(move |(i, _)| {
        let end = text[i + 1..].find(';')?;
        let name = &text[i + 1..i + 1 + end];
        entities.get_key_value(name).map(|(name, _)| *name)
    })
}

/// An entity's expanded size: its largest value plus what each reference in
/// that value expands to. A reference cycle, which roxmltree rejects anyway,
/// counts as unbounded.
fn size<'a>(
    name: &'a str,
    entities: &HashMap<&'a str, Vec<&'a str>>,
    sizes: &mut HashMap<&'a str, Option<u64>>,
) -> u64 {
    match sizes.get(name) {
        Some(Some(size)) => return *size,
        Some(None) => return u64::MAX,
        None => {}
    }
    sizes.insert(name, None);

    let total = entities[name]
        .iter()
        .map(|value| {
            references(value, entities)
                .map(|reference| size(reference, entities, sizes))
                .fold(value.len() as u64, u64::saturating_add)
        })
        .max()
        .unwrap_or(0);

    sizes.insert(name, Some(total));
    total
}
