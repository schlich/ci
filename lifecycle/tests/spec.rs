//! Conformance with `JjCi.tla` over the bounded model in `JjCi.cfg`.
//!
//! `step` transcribes each TLA+ action over the model's flat variables,
//! independently of the state machine. A breadth-first search from every
//! initial state then checks, for every reachable state and every event, that
//! the machine accepts exactly the events whose action is enabled and lands on
//! the same variables, and that every invariant of the model holds.

use std::collections::{HashSet, VecDeque};

use jj_ci_lifecycle::{apply, Commit, Event, Machine, State, Topic, Workspace};

const HEADS: [&str; 2] = ["h0", "h1"];
const MAIN_HEADS: [&str; 2] = ["m0", "m1"];

/// The variables of `JjCi.tla`, with `"none"` as `None`.
#[derive(Clone, Debug, PartialEq, Eq)]
struct Vars {
    owner: bool,
    active: bool,
    head: Commit,
    base: Commit,
    conflict: bool,
    validated: bool,
    validated_head: Option<Commit>,
    published: bool,
    published_head: Option<Commit>,
    published_validated: bool,
    published_validation_head: Option<Commit>,
    published_conflict_free: bool,
    published_fresh: bool,
    passed_head: Option<Commit>,
    parent_landed: bool,
    main_head: Commit,
    landed_onto: Option<Commit>,
    delivered: bool,
    workspace_base: &'static str,
}

fn workspace_base(workspace: Workspace) -> &'static str {
    match workspace {
        Workspace::Main => "main",
        Workspace::Dropped => "dropped",
    }
}

fn project(machine: &Machine) -> Vars {
    let topic = machine.inner();
    let state = machine.state();
    let released = matches!(state, State::Released { .. });
    let validated = matches!(state, State::Validated { .. });
    let publication = topic.publication.as_ref();
    Vars {
        owner: !released,
        active: !released,
        head: topic.head.clone(),
        base: topic.base.clone(),
        conflict: matches!(state, State::Conflicted { .. }),
        validated,
        validated_head: validated.then(|| topic.head.clone()),
        published: publication.is_some(),
        published_head: publication.map(|p| p.head.clone()),
        published_validated: publication.is_some(),
        published_validation_head: publication.map(|p| p.validated_head.clone()),
        published_conflict_free: publication.is_some_and(|p| p.conflict_free),
        published_fresh: publication.is_some_and(|p| p.fresh),
        passed_head: topic.passed.clone(),
        parent_landed: topic.parent_landed,
        main_head: topic.main.clone(),
        landed_onto: topic.landed_onto.clone(),
        delivered: matches!(
            state,
            State::Delivered { .. }
                | State::Released {
                    delivered: true,
                    ..
                }
        ),
        workspace_base: match state {
            State::Released { workspace, .. } => workspace_base(*workspace),
            _ => "topic",
        },
    }
}

/// Validation only enables publication, which delivery and release rule out,
/// so the machine does not carry it into those states.
fn normalize(mut vars: Vars) -> Vars {
    if vars.delivered || !vars.owner {
        vars.validated = false;
        vars.validated_head = None;
    }
    vars
}

/// The TLA+ action an event stands for, or `None` when it is disabled.
fn step(v: &Vars, event: &Event) -> Option<Vars> {
    let mut n = v.clone();
    let owned = v.owner && v.active;
    match event {
        Event::Edit { head } => {
            if !(owned && !v.delivered) {
                return None;
            }
            n.head = head.clone();
            n.validated = false;
            n.validated_head = None;
        }
        Event::Rebase { head, conflicted } => {
            if !(owned && !v.conflict && !v.delivered) {
                return None;
            }
            n.base = v.main_head.clone();
            n.head = head.clone();
            n.conflict = *conflicted;
            n.validated = false;
            n.validated_head = None;
        }
        Event::Resolve => {
            if !(owned && v.conflict && !v.delivered) {
                return None;
            }
            n.conflict = false;
            n.validated = false;
            n.validated_head = None;
        }
        Event::Validate => {
            if !(owned && !v.conflict && !v.delivered) {
                return None;
            }
            n.validated = true;
            n.validated_head = Some(v.head.clone());
        }
        Event::Publish => {
            if !(owned
                && v.validated
                && v.validated_head.as_ref() == Some(&v.head)
                && !v.conflict
                && !v.delivered
                && v.base == v.main_head)
            {
                return None;
            }
            n.published_fresh = v.base == v.main_head;
            n.published = true;
            n.published_head = Some(v.head.clone());
            n.published_validated = v.validated;
            n.published_validation_head = v.validated_head.clone();
            n.published_conflict_free = !v.conflict;
        }
        Event::GatePasses => {
            if !v.published {
                return None;
            }
            n.passed_head = v.published_head.clone();
        }
        Event::ParentLands => {
            if v.parent_landed {
                return None;
            }
            n.parent_landed = true;
        }
        Event::TrunkAdvances { main } => {
            if v.delivered || *main == v.main_head {
                return None;
            }
            n.main_head = main.clone();
        }
        Event::Land => {
            if !(owned
                && v.published
                && !v.conflict
                && !v.delivered
                && v.parent_landed
                && v.published_head.as_ref() == Some(&v.head)
                && v.passed_head.as_ref() == Some(&v.head)
                && v.base == v.main_head)
            {
                return None;
            }
            n.landed_onto = Some(v.main_head.clone());
            n.main_head = v.head.clone();
            n.delivered = true;
        }
        Event::Finish { workspace } => {
            if !(owned && !v.conflict && (v.delivered || !v.published)) {
                return None;
            }
            n.owner = false;
            n.active = false;
            n.workspace_base = workspace_base(*workspace);
        }
        Event::Abandon { workspace } => {
            if !(owned && !v.published) {
                return None;
            }
            n.owner = false;
            n.active = false;
            n.conflict = false;
            n.workspace_base = workspace_base(*workspace);
        }
    }
    Some(n)
}

fn invariants(v: &Vars) -> Vec<&'static str> {
    let is_head = |c: &Commit| HEADS.contains(&c.as_str());
    let checks = [
        (
            "NoPublishWhileUnsafe",
            !v.published
                || (v.published_head.as_ref().is_some_and(is_head)
                    && v.published_validated
                    && v.published_conflict_free),
        ),
        ("PublishedFromFreshBase", !v.published || v.published_fresh),
        (
            "PublishedHeadWasValidated",
            !v.published || v.published_head == v.published_validation_head,
        ),
        ("NoFinishWithConflict", !(!v.owner && v.conflict)),
        (
            "FinishLeavesMain",
            v.active || matches!(v.workspace_base, "main" | "dropped"),
        ),
        (
            "NoDropWhilePending",
            v.workspace_base != "dropped" || (!v.owner && (v.delivered || !v.published)),
        ),
        (
            "MainOnlyHoldsPassedHeads",
            !is_head(&v.main_head) || v.passed_head.as_ref() == Some(&v.main_head),
        ),
        (
            "DeliveryIsPublishedHead",
            !v.delivered || v.published_head.as_ref() == Some(&v.main_head),
        ),
        (
            "DeliveredHeadIsLocal",
            !v.delivered || v.main_head == v.head,
        ),
        ("LandsAfterParent", !v.delivered || v.parent_landed),
        (
            "LandingIsFastForward",
            !v.delivered || v.landed_onto.as_ref() == Some(&v.base),
        ),
    ];
    checks
        .into_iter()
        .filter(|(_, holds)| !holds)
        .map(|(name, _)| name)
        .collect()
}

fn events() -> Vec<Event> {
    let mut events = vec![
        Event::Resolve,
        Event::Validate,
        Event::Publish,
        Event::GatePasses,
        Event::ParentLands,
        Event::Land,
    ];
    for head in HEADS {
        events.push(Event::Edit { head: head.into() });
        for conflicted in [false, true] {
            events.push(Event::Rebase {
                head: head.into(),
                conflicted,
            });
        }
    }
    for main in MAIN_HEADS {
        events.push(Event::TrunkAdvances { main: main.into() });
    }
    for workspace in [Workspace::Main, Workspace::Dropped] {
        events.push(Event::Finish { workspace });
        events.push(Event::Abandon { workspace });
    }
    events
}

fn initial_machines() -> Vec<Machine> {
    let mut machines = Vec::new();
    for head in HEADS {
        for base in MAIN_HEADS {
            for parent_landed in [false, true] {
                machines.push(Topic::new(head, base, parent_landed).machine());
            }
        }
    }
    machines
}

#[test]
fn the_machine_refines_the_tla_model() {
    let events = events();
    let mut seen = HashSet::new();
    let mut queue: VecDeque<Machine> = initial_machines().into();
    for machine in &queue {
        seen.insert((machine.state().clone(), machine.inner().clone()));
    }
    let mut delivered = 0;
    while let Some(machine) = queue.pop_front() {
        let vars = project(&machine);
        let broken = invariants(&vars);
        assert!(broken.is_empty(), "{broken:?} broken in {vars:#?}");
        delivered += usize::from(vars.delivered);

        for event in &events {
            let mut next = machine.clone();
            let accepted = apply(&mut next, event);
            let expected = step(&vars, event);
            assert_eq!(
                accepted,
                expected.is_some(),
                "{event:?} from {:?} {vars:#?}",
                machine.state()
            );
            match expected {
                Some(expected) => assert_eq!(
                    normalize(project(&next)),
                    normalize(expected),
                    "{event:?} from {:?}",
                    machine.state()
                ),
                None => assert!(next == machine, "rejected {event:?} changed the machine"),
            }
            if seen.insert((next.state().clone(), next.inner().clone())) {
                queue.push_back(next);
            }
        }
    }
    // The bounded model is small, but it must reach delivery to mean anything.
    assert!(delivered > 0, "no reachable state delivers the topic");
    assert!(seen.len() > 100, "only {} states reached", seen.len());
}

#[test]
fn a_topic_lands_only_through_validation_publication_and_a_gate() {
    let mut machine = Topic::new("h0", "m0", true).machine();
    assert!(!apply(&mut machine, &Event::Land));
    assert!(!apply(&mut machine, &Event::Publish));
    assert!(apply(&mut machine, &Event::Validate));
    assert!(apply(&mut machine, &Event::Publish));
    assert!(!apply(&mut machine, &Event::Land));
    assert!(apply(&mut machine, &Event::GatePasses));
    assert!(apply(&mut machine, &Event::Land));
    assert!(matches!(machine.state(), State::Delivered { .. }));
    assert_eq!(machine.inner().main, "h0");
    assert_eq!(machine.inner().landed_onto.as_deref(), Some("m0"));
}

#[test]
fn trunk_moving_after_publication_blocks_landing_until_republished() {
    let mut machine = Topic::new("h0", "m0", true).machine();
    for event in [Event::Validate, Event::Publish, Event::GatePasses] {
        assert!(apply(&mut machine, &event));
    }
    assert!(apply(
        &mut machine,
        &Event::TrunkAdvances { main: "m1".into() }
    ));
    assert!(!apply(&mut machine, &Event::Land));
    for event in [
        Event::Rebase {
            head: "h1".into(),
            conflicted: false,
        },
        Event::Validate,
        Event::Publish,
        Event::GatePasses,
        Event::Land,
    ] {
        assert!(apply(&mut machine, &event), "{event:?}");
    }
    assert_eq!(machine.inner().landed_onto.as_deref(), Some("m1"));
}
