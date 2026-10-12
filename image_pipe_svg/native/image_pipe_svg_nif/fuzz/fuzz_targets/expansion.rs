#![no_main]

//! The element limit is checked against an estimate made before usvg builds
//! its tree. Whenever a document passes, the tree usvg builds must stay
//! within a small multiple of that estimate: usvg adds a few nodes of its
//! own per element, such as the group around a `<use>` copy, but a document
//! that builds many times more than the estimate has found a copy the
//! estimate doesn't count.

#[path = "common.rs"]
mod common;

use image_pipe_svg_nif_fuzz::parse::{estimated_elements, parse};
use std::collections::HashSet;

use libfuzzer_sys::fuzz_target;
use resvg::usvg::{Group, Node};

/// usvg nodes allowed per estimated element, and a constant for the root.
const FACTOR: u64 = 4;
const SLACK: u64 = 16;

fuzz_target!(|data: &[u8]| {
    let Ok(text) = std::str::from_utf8(data) else {
        return;
    };
    common::on_stack(|| {
        let Some(estimate) = estimated_elements(text, &common::LIMITS) else {
            return;
        };
        let Ok(tree) = parse(data, common::fonts(), &common::LIMITS) else {
            return;
        };
        let nodes = count(tree.root());
        assert!(
            nodes <= FACTOR * estimate + SLACK,
            "usvg built {nodes} nodes from an estimate of {estimate} elements"
        );
    });
});

/// Every node usvg built, including the content of clip paths, masks,
/// patterns, and filters. Content usvg shares between references counts
/// once, as usvg stores it once; content it copies per reference counts per
/// copy. Embedded SVGs are left out: they share the limits through the
/// resolver, not this estimate.
fn count(group: &Group) -> u64 {
    let mut seen = HashSet::new();
    count_group(group, &mut seen)
}

fn count_group(group: &Group, seen: &mut HashSet<*const Group>) -> u64 {
    1 + group
        .children()
        .iter()
        .map(|node| count_node(node, seen))
        .sum::<u64>()
}

fn count_node(node: &Node, seen: &mut HashSet<*const Group>) -> u64 {
    let mut total = match node {
        Node::Group(group) => count_group(group, seen),
        Node::Image(_) => return 1,
        _ => 1,
    };
    node.subroots(|root| {
        if seen.insert(root as *const Group) {
            total += count_group(root, seen);
        }
    });
    total
}
