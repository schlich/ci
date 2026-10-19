//! The Mermaid diagram draws exactly what the machine does.

use jj_ci_lifecycle::diagram::{mermaid, Node, EDGES};
use jj_ci_lifecycle::{apply, Publication, Topic};

/// A topic whose facts satisfy the edge's guard: landing needs a published
/// head the gate passed, on the runway; the rest need no publication.
fn topic(landing: bool) -> Topic {
    let mut topic = Topic::new("c1", "t1", true);
    if landing {
        topic.publication = Some(Publication {
            head: "c1".into(),
            validated_head: "c1".into(),
            conflict_free: true,
            fresh: true,
        });
        topic.passed = Some("c1".into());
        topic.on_runway = true;
    }
    topic
}

#[test]
fn every_edge_is_a_transition_of_the_machine() {
    for edge in EDGES {
        let event = (edge.event)();
        let landing = edge.to == Node::Delivered;
        let mut machine = topic(landing).restore(edge.from.state());
        assert!(
            apply(&mut machine, &event),
            "{} rejects {:?}",
            edge.from.name(),
            event
        );
        assert_eq!(
            Node::of(machine.state()),
            edge.to,
            "{} --{}--> {}",
            edge.from.name(),
            edge.label,
            edge.to.name()
        );
    }
}

#[test]
fn every_state_is_drawn_and_named() {
    let source = mermaid(None);
    for node in Node::ALL {
        assert!(source.contains(node.name()), "{} is missing", node.name());
        assert_eq!(Node::parse(node.name()), Some(node));
    }
    assert!(!source.contains("classDef"));
}

#[test]
fn the_current_state_is_highlighted() {
    let source = mermaid(Some(Node::Validated));
    assert!(source.contains("class validated current"));
    assert_eq!(source.matches("class ").count(), 1);
}
