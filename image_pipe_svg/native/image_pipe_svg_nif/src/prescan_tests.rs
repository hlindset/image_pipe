//! Property tests for the checks that read a document before roxmltree and
//! usvg do. They guard untrusted input, so they must never panic, must stay
//! linear in the length of the input, and must never count low.

use std::time::{Duration, Instant};

use proptest::prelude::*;
use resvg::usvg::roxmltree;

use crate::entities;
use crate::parse::max_depth;

/// Fragments that steer the scanners into their edge cases.
fn fragment() -> impl Strategy<Value = String> {
    prop_oneof![
        Just("<!ENTITY ".to_string()),
        Just("<!ENTITY % ".to_string()),
        Just("<!DOCTYPE svg ".to_string()),
        Just("SYSTEM \"a>b\" ".to_string()),
        Just("[".to_string()),
        Just("]".to_string()),
        Just("<".to_string()),
        Just(">".to_string()),
        Just("</".to_string()),
        Just("/>".to_string()),
        Just("<!--".to_string()),
        Just("-->".to_string()),
        Just("<![CDATA[".to_string()),
        Just("]]>".to_string()),
        Just("<?".to_string()),
        Just("?>".to_string()),
        Just("\"".to_string()),
        Just("'".to_string()),
        Just("&".to_string()),
        Just(";".to_string()),
        Just("&a;".to_string()),
        Just(" ".to_string()),
        Just("é".to_string()),
        "[a-z]{1,3}",
    ]
}

fn soup() -> impl Strategy<Value = String> {
    prop::collection::vec(fragment(), 0..200).prop_map(|fragments| fragments.concat())
}

/// A step in building a well-formed document.
#[derive(Clone, Debug)]
enum Step {
    Open,
    Close,
    Empty,
    Text,
    Noise(usize),
}

/// Markup that holds tag-like text the depth scan must skip.
const NOISE: [&str; 6] = [
    "<!-- <g><g> ' \" -->",
    "<![CDATA[<g><g> ' \"]]>",
    "<?pi <g> ' ?>",
    "&gt;&lt;g&gt;",
    "&e;",
    "<r a='g>' b=\"x>y\"/>",
];

fn steps() -> impl Strategy<Value = Vec<Step>> {
    let step = prop_oneof![
        3 => Just(Step::Open),
        2 => Just(Step::Close),
        1 => Just(Step::Empty),
        1 => Just(Step::Text),
        2 => (0..NOISE.len()).prop_map(Step::Noise),
    ];
    prop::collection::vec(step, 0..300)
}

/// A well-formed document from `steps`, with a DOCTYPE whose subset holds
/// quotes, a `>`, a comment, and a processing instruction.
fn document(steps: &[Step]) -> String {
    let mut text = String::from(
        "<!DOCTYPE svg SYSTEM \"a>b\" [<!-- ' --><?pi \" ?><!ENTITY e \"x>y\">]><svg>",
    );
    let mut open = 0;
    for step in steps {
        match step {
            Step::Open => {
                text.push_str("<g k='>'>");
                open += 1;
            }
            Step::Close if open > 0 => {
                text.push_str("</g>");
                open -= 1;
            }
            Step::Close => {}
            Step::Empty => text.push_str("<e/>"),
            Step::Text => text.push('t'),
            Step::Noise(i) => text.push_str(NOISE[*i]),
        }
    }
    text.push_str(&"</g>".repeat(open));
    text.push_str("</svg>");
    text
}

fn parse(text: &str) -> roxmltree::Document<'_> {
    let options = roxmltree::ParsingOptions {
        allow_dtd: true,
        ..Default::default()
    };
    roxmltree::Document::parse_with_options(text, options).expect("a well-formed document")
}

/// How deep elements nest, counting the root as 1.
fn element_depth(doc: &roxmltree::Document) -> usize {
    doc.descendants()
        .filter(roxmltree::Node::is_element)
        .map(|node| node.ancestors().filter(roxmltree::Node::is_element).count())
        .max()
        .unwrap_or(0)
}

/// Entities that each reference only earlier ones, so none loops.
#[derive(Clone, Debug)]
struct Declared {
    literals: Vec<usize>,
    references: Vec<Vec<usize>>,
}

fn declared() -> impl Strategy<Value = (Declared, Vec<usize>)> {
    (1usize..6).prop_flat_map(|count| {
        let literals = prop::collection::vec(0usize..20, count);
        let references = (0..count)
            .map(|i| prop::collection::vec(0..i.max(1), 0..if i == 0 { 1 } else { 4 }))
            .collect::<Vec<_>>();
        let used = prop::collection::vec(0..count, 0..20);
        (literals, references, used).prop_map(|(literals, references, used)| {
            (
                Declared {
                    literals,
                    references,
                },
                used,
            )
        })
    })
}

fn entity_document(declared: &Declared, used: &[usize]) -> String {
    let mut text = String::from("<!DOCTYPE svg [");
    // A smaller decoy of the same name, which the bound must not trust.
    text.push_str("<!-- <!ENTITY e0 \"\"> -->");
    for (i, literal) in declared.literals.iter().enumerate() {
        let references: String = declared.references[i]
            .iter()
            .filter(|&&j| j < i)
            .map(|j| format!("&e{j};"))
            .collect();
        text.push_str(&format!(
            "<!ENTITY e{i} \"{}{references}\">",
            "x".repeat(*literal)
        ));
    }
    text.push_str("]><svg>");
    for &i in used {
        text.push_str(&format!("<text a=\"&e{i};\">&e{i};</text>"));
    }
    text.push_str("</svg>");
    text
}

proptest! {
    #[test]
    fn scans_never_panic(text in prop_oneof![soup(), any::<String>()]) {
        entities::scan(&text);
        max_depth(&text, usize::MAX);
    }

    #[test]
    fn depth_matches_roxmltree(steps in steps()) {
        let text = document(&steps);
        let doc = parse(&text);
        prop_assert_eq!(max_depth(&text, usize::MAX), element_depth(&doc));
    }

    #[test]
    fn expansion_bounds_what_roxmltree_expands((declared, used) in declared()) {
        let text = entity_document(&declared, &used);
        let doc = parse(&text);
        let expanded: usize = doc
            .descendants()
            .map(|node| {
                if node.is_text() {
                    node.text().map_or(0, str::len)
                } else {
                    node.attributes().map(|a| a.value().len()).sum()
                }
            })
            .sum();
        let bound = text.len() as u64 + entities::scan(&text).expansion;
        prop_assert!(expanded as u64 <= bound, "{expanded} > {bound}");
    }
}

/// The fastest of a few runs, to keep a busy machine from failing the test.
fn time(scan: impl Fn()) -> Duration {
    (0..3)
        .map(|_| {
            let start = Instant::now();
            scan();
            start.elapsed()
        })
        .min()
        .unwrap()
}

/// Eight times the input must take nowhere near 64 times as long, which a
/// quadratic scan would.
#[test]
fn scans_stay_linear() {
    let inputs: [fn(usize) -> String; 8] = [
        |n| "&".repeat(n),
        |n| "&a".repeat(n),
        |n| "<!ENTITY ".repeat(n),
        |n| format!("<!ENTITY a \"{}", "<!ENTITY b '".repeat(n)),
        |n| "<".repeat(n),
        |n| "<!--".repeat(n),
        |n| format!("<!DOCTYPE [{}", "<?".repeat(n)),
        |n| format!("<a b='{}", "<a ".repeat(n)),
    ];
    for input in inputs {
        let (small, large) = (input(20_000), input(160_000));
        let scan = |text: &str| {
            entities::scan(text);
            max_depth(text, usize::MAX);
        };
        let (fast, slow) = (time(|| scan(&small)), time(|| scan(&large)));
        assert!(
            slow < fast * 20 + Duration::from_millis(20),
            "{:?} for 8x the input of {:?}, starting {:?}",
            slow,
            fast,
            &small[..small.len().min(20)]
        );
    }
}
