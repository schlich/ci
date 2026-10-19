//! The lifecycle as a Mermaid state diagram, for agents and docs.
//!
//! The leaf states are drawn inside their `working` and `clean` superstates.
//! Facts the machine keeps in storage (the hold, the runway, a gate's verdict,
//! trunk advancing) are guards on these transitions, not states, so they
//! appear only in the labels. `tests/diagram.rs` drives every edge through the
//! machine, so the drawing cannot drift from it.

use crate::{Event, State, Workspace};

/// A leaf state of the machine, as the diagram names it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Node {
    Editing,
    Validated,
    Conflicted,
    Delivered,
    Released,
}

impl Node {
    pub const ALL: [Node; 5] = [
        Node::Editing,
        Node::Validated,
        Node::Conflicted,
        Node::Delivered,
        Node::Released,
    ];

    pub fn of(state: &State) -> Node {
        match state {
            State::Editing { .. } => Node::Editing,
            State::Validated { .. } => Node::Validated,
            State::Conflicted { .. } => Node::Conflicted,
            State::Delivered { .. } => Node::Delivered,
            State::Released { .. } => Node::Released,
        }
    }

    /// A state this node draws; a released one is an undelivered release.
    pub fn state(self) -> State {
        match self {
            Node::Editing => State::editing(),
            Node::Validated => State::validated(),
            Node::Conflicted => State::conflicted(),
            Node::Delivered => State::delivered(),
            Node::Released => State::released(Workspace::Main, false),
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Node::Editing => "editing",
            Node::Validated => "validated",
            Node::Conflicted => "conflicted",
            Node::Delivered => "delivered",
            Node::Released => "released",
        }
    }

    pub fn parse(name: &str) -> Option<Node> {
        Node::ALL.into_iter().find(|node| node.name() == name)
    }
}

/// One transition: the state it leaves, its label, the event that takes it,
/// and the state it enters.
pub struct Edge {
    pub from: Node,
    pub label: &'static str,
    pub event: fn() -> Event,
    pub to: Node,
}

fn edit() -> Event {
    Event::Edit {
        head: "edited".into(),
    }
}

fn rebase() -> Event {
    Event::Rebase {
        head: "rebased".into(),
        conflicted: false,
    }
}

fn rebase_conflicted() -> Event {
    Event::Rebase {
        head: "rebased".into(),
        conflicted: true,
    }
}

fn finish() -> Event {
    Event::Finish {
        workspace: Workspace::Main,
    }
}

fn abandon() -> Event {
    Event::Abandon {
        workspace: Workspace::Main,
    }
}

pub const EDGES: &[Edge] = &[
    Edge {
        from: Node::Editing,
        label: "Edit",
        event: edit,
        to: Node::Editing,
    },
    Edge {
        from: Node::Editing,
        label: "Rebase",
        event: rebase,
        to: Node::Editing,
    },
    Edge {
        from: Node::Editing,
        label: "Validate (ci preflight)",
        event: || Event::Validate,
        to: Node::Validated,
    },
    Edge {
        from: Node::Validated,
        label: "Publish (ci dispatch)",
        event: || Event::Publish,
        to: Node::Validated,
    },
    Edge {
        from: Node::Validated,
        label: "Edit",
        event: edit,
        to: Node::Editing,
    },
    Edge {
        from: Node::Validated,
        label: "Rebase",
        event: rebase,
        to: Node::Editing,
    },
    Edge {
        from: Node::Editing,
        label: "Rebase (conflicted)",
        event: rebase_conflicted,
        to: Node::Conflicted,
    },
    Edge {
        from: Node::Validated,
        label: "Rebase (conflicted)",
        event: rebase_conflicted,
        to: Node::Conflicted,
    },
    Edge {
        from: Node::Conflicted,
        label: "Edit",
        event: edit,
        to: Node::Conflicted,
    },
    Edge {
        from: Node::Conflicted,
        label: "Resolve",
        event: || Event::Resolve,
        to: Node::Editing,
    },
    Edge {
        from: Node::Validated,
        label: "Land (on the runway, gate passed the head)",
        event: || Event::Land,
        to: Node::Delivered,
    },
    Edge {
        from: Node::Editing,
        label: "Finish (ci park, unpublished)",
        event: finish,
        to: Node::Released,
    },
    Edge {
        from: Node::Validated,
        label: "Finish (ci park, unpublished)",
        event: finish,
        to: Node::Released,
    },
    Edge {
        from: Node::Editing,
        label: "Abandon (ci cancel, unpublished)",
        event: abandon,
        to: Node::Released,
    },
    Edge {
        from: Node::Validated,
        label: "Abandon (ci cancel, unpublished)",
        event: abandon,
        to: Node::Released,
    },
    Edge {
        from: Node::Conflicted,
        label: "Abandon (ci cancel, unpublished)",
        event: abandon,
        to: Node::Released,
    },
    Edge {
        from: Node::Delivered,
        label: "Finish (ci park)",
        event: finish,
        to: Node::Released,
    },
];

/// The Mermaid `stateDiagram-v2` source, with `current` highlighted.
/// Parallel edges share one arrow, their labels joined.
pub fn mermaid(current: Option<Node>) -> String {
    let mut arrows: Vec<(Node, Node, Vec<&str>)> = Vec::new();
    for edge in EDGES {
        match arrows
            .iter_mut()
            .find(|(from, to, _)| *from == edge.from && *to == edge.to)
        {
            Some((_, _, labels)) if labels.contains(&edge.label) => {}
            Some((_, _, labels)) => labels.push(edge.label),
            None => arrows.push((edge.from, edge.to, vec![edge.label])),
        }
    }
    let inside = |node: Node| matches!(node, Node::Editing | Node::Validated | Node::Conflicted);
    let clean = |node: Node| matches!(node, Node::Editing | Node::Validated);
    let line = |(from, to, labels): &(Node, Node, Vec<&str>)| {
        format!("{} --> {} : {}", from.name(), to.name(), labels.join(" / "))
    };

    let mut out = vec![
        "stateDiagram-v2".to_string(),
        "  [*] --> editing".to_string(),
        "  state topic {".to_string(),
        "    state \"working (owned)\" as working {".to_string(),
        "      state clean {".to_string(),
    ];
    for arrow in arrows.iter().filter(|(f, t, _)| clean(*f) && clean(*t)) {
        out.push(format!("        {}", line(arrow)));
    }
    out.push("      }".to_string());
    for arrow in arrows
        .iter()
        .filter(|(f, t, _)| inside(*f) && inside(*t) && !(clean(*f) && clean(*t)))
    {
        out.push(format!("      {}", line(arrow)));
    }
    out.push("    }".to_string());
    out.push("    delivered".to_string());
    out.push("    released".to_string());
    out.push("  }".to_string());
    for arrow in arrows
        .iter()
        .filter(|(f, t, _)| !(inside(*f) && inside(*t)))
    {
        out.push(format!("  {}", line(arrow)));
    }
    out.push("  released --> [*]".to_string());
    if let Some(node) = current {
        out.push("  classDef current stroke-width:3px,font-weight:bold".to_string());
        out.push(format!("  class {} current", node.name()));
    }
    out.join("\n") + "\n"
}
