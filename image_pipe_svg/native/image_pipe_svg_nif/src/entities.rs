//! An upper bound on how much text an SVG's entities expand to, found in one
//! pass before parsing.
//!
//! roxmltree limits each top-level entity reference to 255 nested ones but not
//! the total, so a few kilobytes of declarations and references can expand to
//! hundreds of megabytes during parsing. Rejecting such a document before the
//! parse is the only way to avoid allocating that memory.

use std::collections::HashMap;

/// The total characters the document's entity references expand to, counting
/// each reference outside the internal DTD subset once per occurrence. Text
/// that roxmltree wouldn't expand, such as a reference in a comment, still
/// counts, so the bound only errs high.
pub fn expanded_size(text: &str) -> u64 {
    let Some((entities, body)) = declarations(text) else {
        return 0;
    };
    if entities.is_empty() {
        return 0;
    }

    let mut sizes = HashMap::new();
    references(body, &entities)
        .map(|name| size(name, &entities, &mut sizes))
        .fold(0u64, u64::saturating_add)
}

/// The quoted entity values declared in the internal subset, and the text
/// after it. roxmltree registers general and parameter entities alike.
fn declarations(text: &str) -> Option<(HashMap<&str, &str>, &str)> {
    let doctype = text.find("<!DOCTYPE")?;
    let rest = &text[doctype..];
    let bytes = rest.as_bytes();
    let mut entities = HashMap::new();
    let mut i = 0;

    // A DOCTYPE without an internal subset declares nothing.
    loop {
        match bytes.get(i)? {
            b'[' => break,
            b'>' => return Some((entities, &rest[i..])),
            _ => i += 1,
        }
    }
    i += 1;

    while let Some(&byte) = bytes.get(i) {
        if byte == b']' {
            return Some((entities, &rest[i..]));
        } else if rest[i..].starts_with("<!--") {
            i += rest[i..].find("-->").map_or(bytes.len(), |end| end + 3);
        } else if rest[i..].starts_with("<!ENTITY") {
            i = entity(rest, i + 8, &mut entities);
        } else if byte == b'"' || byte == b'\'' {
            i = closing_quote(rest, i);
        } else {
            i += 1;
        }
    }
    Some((entities, ""))
}

/// Records one `<!ENTITY [%] name "value">` starting after `<!ENTITY`, and
/// returns where scanning continues.
fn entity<'a>(text: &'a str, mut i: usize, entities: &mut HashMap<&'a str, &'a str>) -> usize {
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
            entities.entry(name).or_insert(value);
            end
        }
        _ => i,
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
    entities: &HashMap<&'k str, &'k str>,
) -> impl Iterator<Item = &'k str> {
    text.match_indices('&').filter_map(move |(i, _)| {
        let end = text[i + 1..].find(';')?;
        let name = &text[i + 1..i + 1 + end];
        entities.get_key_value(name).map(|(name, _)| *name)
    })
}

/// An entity's expanded size: its value plus what each reference in it
/// expands to. A reference cycle, which roxmltree rejects anyway, counts as
/// unbounded.
fn size<'a>(
    name: &'a str,
    entities: &HashMap<&'a str, &'a str>,
    sizes: &mut HashMap<&'a str, Option<u64>>,
) -> u64 {
    match sizes.get(name) {
        Some(Some(size)) => return *size,
        Some(None) => return u64::MAX,
        None => {}
    }
    sizes.insert(name, None);

    let value = entities[name];
    let total = references(value, entities)
        .map(|reference| size(reference, entities, sizes))
        .fold(value.len() as u64, u64::saturating_add);

    sizes.insert(name, Some(total));
    total
}
