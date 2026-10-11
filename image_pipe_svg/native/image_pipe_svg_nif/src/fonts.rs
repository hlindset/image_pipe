use resvg::usvg::fontdb::{self, Database};

/// Builds a font database from the host's font files, never from system fonts.
///
/// Generic families (`serif`, `sans-serif`, ...) resolve to `fallback`. usvg
/// falls back to the serif family when a named family is missing, so text in
/// an unknown family also renders in `fallback`. Without a fallback, the
/// generic families name nothing, and such text is left out.
pub fn load(files: Vec<(String, Vec<u8>)>, fallback: Option<String>) -> Result<Database, String> {
    let mut db = Database::new();

    for (name, data) in files {
        let ids = db.load_font_source(fontdb::Source::Binary(std::sync::Arc::new(data)));
        if ids.is_empty() {
            return Err(format!("not a font file: {name}"));
        }
    }

    let family = match fallback {
        Some(family) => {
            let known = db
                .faces()
                .any(|face| face.families.iter().any(|(name, _)| *name == family));
            if !known {
                return Err(format!(
                    "fallback family isn't among the loaded fonts: {family}"
                ));
            }
            family
        }
        // No face has an empty family name, so nothing matches.
        None => String::new(),
    };

    db.set_serif_family(family.clone());
    db.set_sans_serif_family(family.clone());
    db.set_cursive_family(family.clone());
    db.set_fantasy_family(family.clone());
    db.set_monospace_family(family);
    Ok(db)
}
