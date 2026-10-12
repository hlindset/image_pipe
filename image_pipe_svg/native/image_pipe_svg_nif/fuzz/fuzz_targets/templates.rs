#![no_main]

//! Places the fuzzer's bytes where usvg copies or expands content, repeated
//! many times, so the fuzzer spends its time on the shapes of input the
//! limits exist for instead of rediscovering XML. The first byte picks the
//! template, the second how many times it's used.

#[path = "common.rs"]
mod common;

use base64::Engine;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let [template, uses, payload @ ..] = data else {
        return;
    };
    let payload = String::from_utf8_lossy(payload);
    let uses = usize::from(*uses) * 40;
    let svg = document(*template, uses, &payload);
    common::parse_and_render(svg.as_bytes());
});

fn document(template: u8, uses: usize, payload: &str) -> String {
    let open = r#"<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="64" height="64">"#;
    let rects = |attribute: &str| format!(r#"<rect width="8" height="8" {attribute}/>"#).repeat(uses);
    let body = match template % 9 {
        0 => {
            return format!(
                "<!DOCTYPE svg [<!ENTITY a \"{payload}\">]>{open}<text>{}</text></svg>",
                "&a;".repeat(uses)
            );
        }
        1 => {
            let points: Vec<String> = (0..uses).map(|i| format!("{},{}", i % 64, i / 64)).collect();
            format!(
                r#"<marker id="m">{payload}</marker><polyline marker-mid="url(#m)" points="{}"/>"#,
                points.join(" ")
            )
        }
        2 => format!(
            r#"<clipPath id="c" clipPathUnits="objectBoundingBox">{payload}</clipPath>{}"#,
            rects(r#"clip-path="url(#c)""#)
        ),
        3 => format!(
            r#"<mask id="k" maskContentUnits="objectBoundingBox">{payload}</mask>{}"#,
            rects(r#"mask="url(#k)""#)
        ),
        4 => format!(
            r#"<pattern id="p" width="1" height="1" patternContentUnits="objectBoundingBox">{payload}</pattern>{}"#,
            rects(r#"fill="url(#p)""#)
        ),
        5 => format!(
            r##"<g id="s">{payload}</g><filter id="f"><feImage href="#s"/></filter>{}"##,
            rects(r#"filter="url(#f)""#)
        ),
        6 => {
            let inner = base64::engine::general_purpose::STANDARD.encode(payload);
            format!(
                r##"<image id="i" width="8" height="8" href="data:image/svg+xml;base64,{inner}"/>{}"##,
                r##"<use href="#i"/>"##.repeat(uses)
            )
        }
        7 => format!(r##"<g id="g">{payload}</g>{}"##, r##"<use href="#g"/>"##.repeat(uses)),
        _ => format!("<style>{payload}</style>{}", rects(r#"class="a""#)),
    };
    format!("{open}{body}</svg>")
}
