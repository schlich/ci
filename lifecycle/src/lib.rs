//! The `ci` topic lifecycle modelled by `JjCi.qnt`, as an executable
//! hierarchical state machine.
//!
//! The Quint model tracks the lifecycle state. Here the
//! control facts become states and the data facts stay in shared storage:
//!
//! ```text
//! topic                         GatePasses, ParentLands, OthersLeave;
//! │                             rejects the rest
//! ├── working                   Edit, TrunkAdvances, OthersArrive, Hold,
//! │   │                         DropHold, TakeRunway, LeaveRunway, Abandon
//! │   ├── clean                 Rebase, Validate, Land, Finish
//! │   │   ├── editing
//! │   │   └── validated         Publish
//! │   └── conflicted            Edit keeps the conflict, Resolve
//! ├── delivered                 Finish
//! └── released { workspace, delivered }   TrunkAdvances, OthersArrive
//! ```
//!
//! `owner` and `active` hold exactly outside `released`, `conflict` is the
//! `conflicted` state, and `validated` is the `validated` state, whose head
//! is always the current one. Holding the runway, being held for the
//! drainer, and other topics being ahead are facts (`on_runway`, `held`,
//! `others_ahead`) rather than states, since a topic keeps editing and
//! rebasing through all of them. `tests/spec.rs` checks every transition of
//! the bounded model against the Quint actions, every invariant against the
//! reachable states, and every action property against the transitions.
//!
//! `agent/machine.mjs` refines this protocol into dispatch/landing command
//! states. Its host maps publishing to Publish, holding to Hold, approaching
//! to TakeRunway, clearing to GatePasses, and advancing to Land.
//! Refreshing/republishing invalidates clearance on a rewritten head; bounded
//! retries apply only to a lost landing lease. This lifecycle remains the
//! shared protocol classifier.

pub mod stage;

use statig::prelude::*;

/// A commit ID: a topic head or a trunk tip.
pub type Commit = String;

/// Where a released topic left its workspace.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Workspace {
    /// Kept, on an empty change on main, because `ci start` did not create it.
    Main,
    /// Removed, because `ci start` created it.
    Dropped,
}

/// Something that happens to a topic: a `ci` step or a fact of the outside
/// world. Parameters stand in for the Quint model's nondeterministic choices.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Event {
    /// The working copy changed, giving the topic a new head.
    Edit { head: Commit },
    /// The topic was rebased onto the current trunk, rewriting its head.
    Rebase { head: Commit, conflicted: bool },
    /// The conflicts were resolved.
    Resolve,
    /// Preflight passed on the current head.
    Validate,
    /// `ci dispatch` pushed the validated head.
    Publish,
    /// A gate (the local flake checks, GitHub, or nixbot) passed the published
    /// head.
    GatePasses,
    /// The stack parent landed.
    ParentLands,
    /// Another topic landed and moved trunk.
    TrunkAdvances { main: Commit },
    /// Another topic took the runway or was held, ahead of this one.
    OthersArrive,
    /// The topics ahead of this one landed or dropped out.
    OthersLeave,
    /// `ci queue` held the topic's exact published head for the drainer.
    Hold,
    /// The hold ended without the topic taking the runway: its head changed,
    /// or its owner dropped it.
    DropHold,
    /// The topic took the runway: `ci land` on a clear runway, or the drainer
    /// from its hold.
    TakeRunway,
    /// The landing left the runway without landing. With `requeue`, a
    /// drainer's train that another topic failed put this one back in line,
    /// held at its head.
    LeaveRunway { requeue: bool },
    /// The topic fast-forwarded main to the head the gate passed, from the
    /// runway, which it then left.
    Land,
    /// `ci park` released a delivered or unpublished topic.
    Finish { workspace: Workspace },
    /// `ci cancel` discarded unpublished work.
    Abandon { workspace: Workspace },
}

/// What `ci dispatch` recorded about the head it pushed.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Publication {
    pub head: Commit,
    pub validated_head: Commit,
    pub conflict_free: bool,
    /// Whether the topic was based on the current trunk.
    pub fresh: bool,
}

/// Facts shared by every state.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub struct Topic {
    pub head: Commit,
    /// The trunk the topic is based on.
    pub base: Commit,
    /// The trunk tip.
    pub main: Commit,
    pub publication: Option<Publication>,
    /// The head a gate passed.
    pub passed: Option<Commit>,
    /// False for a topic stacked on an unlanded parent.
    pub parent_landed: bool,
    /// The trunk that landing fast-forwarded from.
    pub landed_onto: Option<Commit>,
    /// Whether the topic holds the runway, where trunk moves for no other
    /// landing.
    pub on_runway: bool,
    /// The head `ci queue` held for the drainer, while the topic is held.
    pub held: Option<Commit>,
    /// Whether another landing is in flight or another topic is held ahead
    /// of this one.
    pub others_ahead: bool,
}

/// Collects whether the machine accepted an event; only the `topic`
/// superstate rejects one, once no state below it handled the event.
#[derive(Debug, Default)]
pub struct Dispatch {
    pub rejected: bool,
}

pub type Machine = InitializedStateMachine<Topic>;

impl Topic {
    /// A fresh topic at `head`, based on and at trunk `base`.
    pub fn new(head: impl Into<Commit>, base: impl Into<Commit>, parent_landed: bool) -> Self {
        let base = base.into();
        Topic {
            head: head.into(),
            main: base.clone(),
            base,
            publication: None,
            passed: None,
            parent_landed,
            landed_onto: None,
            on_runway: false,
            held: None,
            others_ahead: false,
        }
    }

    pub fn machine(self) -> Machine {
        self.uninitialized_state_machine()
            .init_with_context(&mut Dispatch::default())
    }

    /// The machine for a topic observed in `state`, rather than reached by
    /// events. The caller vouches that the facts and the state agree.
    pub fn restore(self, state: State) -> Machine {
        let mut machine = self.machine();
        // SAFETY: statig marks this unsafe only because it can break the
        // machine's own invariants; the caller supplies a consistent state.
        unsafe { *machine.state_mut() = state };
        machine
    }

    fn can_land(&self) -> bool {
        self.publication
            .as_ref()
            .is_some_and(|p| p.head == self.head)
            && self.passed.as_ref() == Some(&self.head)
            && self.parent_landed
            && self.base == self.main
            && self.on_runway
    }

    /// Whether the topic may take the runway now: published, with nothing
    /// ahead of it, and either held at its current head (the drainer) or not
    /// held at all (`ci land`, which only the owner runs, as every working
    /// state is owned).
    fn can_take_runway(&self) -> bool {
        self.publication.is_some()
            && !self.on_runway
            && !self.others_ahead
            && self.held.as_ref().is_none_or(|held| *held == self.head)
    }
}

/// Submits `event` and reports whether the machine accepted it.
pub fn apply(machine: &mut Machine, event: &Event) -> bool {
    let mut dispatch = Dispatch::default();
    machine.handle_with_context(event, &mut dispatch);
    !dispatch.rejected
}

#[state_machine(
    initial = "State::editing()",
    state(derive(Clone, Debug, PartialEq, Eq, Hash)),
    superstate(derive(Debug))
)]
impl Topic {
    #[superstate]
    fn topic(&mut self, context: &mut Dispatch, event: &Event) -> Outcome<State> {
        match event {
            // The gate checks the exact published head, so a verdict never
            // carries over to a rewritten head.
            Event::GatePasses if self.publication.is_some() => {
                self.passed = self.publication.as_ref().map(|p| p.head.clone());
                Handled
            }
            Event::ParentLands if !self.parent_landed => {
                self.parent_landed = true;
                Handled
            }
            Event::OthersLeave if self.others_ahead => {
                self.others_ahead = false;
                Handled
            }
            _ => {
                context.rejected = true;
                Handled
            }
        }
    }

    #[superstate(superstate = "topic")]
    fn working(&mut self, event: &Event) -> Outcome<State> {
        match event {
            Event::Edit { head } => {
                self.head = head.clone();
                Transition(State::editing())
            }
            // Other topics land from the same runway, so not while this one
            // holds it.
            Event::TrunkAdvances { main } if *main != self.main && !self.on_runway => {
                self.main = main.clone();
                Handled
            }
            // Topics that arrive once this one is held or on the runway line
            // up behind it.
            Event::OthersArrive
                if !self.on_runway && self.held.is_none() && !self.others_ahead =>
            {
                self.others_ahead = true;
                Handled
            }
            Event::Hold
                if self.held.is_none()
                    && !self.on_runway
                    && self
                        .publication
                        .as_ref()
                        .is_some_and(|p| p.head == self.head) =>
            {
                self.held = Some(self.head.clone());
                Handled
            }
            Event::DropHold if self.held.is_some() => {
                self.held = None;
                Handled
            }
            Event::TakeRunway if self.can_take_runway() => {
                self.on_runway = true;
                self.held = None;
                Handled
            }
            Event::LeaveRunway { requeue } if self.on_runway => {
                self.on_runway = false;
                self.held = requeue.then(|| self.head.clone());
                Handled
            }
            // Abandoning discards unpublished work, conflicts included.
            Event::Abandon { workspace } if self.publication.is_none() => {
                Transition(State::released(*workspace, false))
            }
            _ => Super,
        }
    }

    #[superstate(superstate = "working")]
    fn clean(&mut self, event: &Event) -> Outcome<State> {
        match event {
            // A rebase onto the current trunk rewrites every commit in the
            // topic, so the head changes too. A clean one leaves the change's
            // own diff alone, so a hold follows it to the new head.
            Event::Rebase { head, conflicted } => {
                self.base = self.main.clone();
                self.head = head.clone();
                if !*conflicted && self.held.is_some() {
                    self.held = Some(head.clone());
                }
                if *conflicted {
                    Transition(State::conflicted())
                } else {
                    Transition(State::editing())
                }
            }
            Event::Validate => Transition(State::validated()),
            // A fast-forward of main to the exact head a gate passed, with a
            // lease on the trunk the topic is based on, from the runway.
            Event::Land if self.can_land() => {
                self.landed_onto = Some(self.main.clone());
                self.main = self.head.clone();
                self.on_runway = false;
                Transition(State::delivered())
            }
            Event::Finish { workspace } if self.publication.is_none() => {
                Transition(State::released(*workspace, false))
            }
            _ => Super,
        }
    }

    #[state(superstate = "clean")]
    fn editing(event: &Event) -> Outcome<State> {
        let _ = event;
        Super
    }

    #[state(superstate = "clean")]
    fn validated(&mut self, event: &Event) -> Outcome<State> {
        match event {
            Event::Publish if self.base == self.main => {
                self.publication = Some(Publication {
                    head: self.head.clone(),
                    validated_head: self.head.clone(),
                    conflict_free: true,
                    fresh: true,
                });
                Handled
            }
            _ => Super,
        }
    }

    #[state(superstate = "working")]
    fn conflicted(&mut self, event: &Event) -> Outcome<State> {
        match event {
            Event::Edit { head } => {
                self.head = head.clone();
                Handled
            }
            Event::Resolve => Transition(State::editing()),
            _ => Super,
        }
    }

    #[state(superstate = "topic")]
    fn delivered(event: &Event) -> Outcome<State> {
        match event {
            Event::Finish { workspace } => Transition(State::released(*workspace, true)),
            _ => Super,
        }
    }

    #[state(superstate = "topic")]
    fn released(
        &mut self,
        workspace: &Workspace,
        delivered: &bool,
        event: &Event,
    ) -> Outcome<State> {
        let _ = workspace;
        match event {
            Event::TrunkAdvances { main } if !*delivered && *main != self.main => {
                self.main = main.clone();
                Handled
            }
            Event::OthersArrive if !*delivered && !self.others_ahead => {
                self.others_ahead = true;
                Handled
            }
            _ => Super,
        }
    }
}
