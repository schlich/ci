//! Where an observed topic stands in the lifecycle, for `context-status`.
//!
//! `context-status` observes a workspace rather than watching events, so the
//! machine is restored from what it sees. The stage then reads the machine,
//! overlaid with the facts the protocol model abstracts away: a working copy
//! that left its topic, an empty stack, and a failed pipeline.

use serde::{Deserialize, Serialize};

use crate::{apply, Commit, Event, Machine, Publication, State, Topic, Workspace};

/// The working copy that left this workspace's recorded topic.
#[derive(Clone, Debug, Deserialize)]
pub struct Stranded {
    pub short: String,
    pub title: String,
    pub stray: String,
}

/// The facts `context-status` collects about the current workspace.
#[derive(Clone, Debug, Deserialize)]
pub struct Observation {
    /// The task owner's status: none, active, delivered, discarded, or released.
    pub owner: String,
    pub stranded: Option<Stranded>,
    /// Whether the dispatched head is on trunk.
    pub landed: bool,
    /// Whether the stack above trunk is empty.
    pub idle: bool,
    pub head: Commit,
    pub described: bool,
    /// The trunk commits the topic lacks.
    pub behind: u64,
    /// The head Tangled holds for the topic's dispatch branch.
    pub published_head: Option<Commit>,
    /// The spindle's verdict on the published head.
    pub spindle: Option<String>,
    /// Whether preflight passed on the current head.
    pub lint_passed: bool,
    pub conflicts: Vec<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Stage {
    Finished,
    Stranded,
    Landed,
    Idle,
    Republish,
    Passed,
    Failed,
    Published,
    Validated,
    Editing,
}

#[derive(Debug, Serialize)]
pub struct Classification {
    pub stage: Stage,
    pub next: String,
    /// The protocol events the machine accepts from here.
    pub allowed: Vec<&'static str>,
}

const TRUNK: &str = "trunk";
const ADVANCED_TRUNK: &str = "trunk+";

impl Observation {
    /// The machine in the state these facts describe. The stack parent is not
    /// observed, so it counts as landed; `ci land` checks it.
    pub fn machine(&self) -> Machine {
        let publication = self.published_head.as_ref().map(|head| Publication {
            head: head.clone(),
            validated_head: head.clone(),
            conflict_free: true,
            fresh: true,
        });
        let passed = match self.spindle.as_deref() {
            Some("success") => self.published_head.clone(),
            _ => None,
        };
        let topic = Topic {
            head: self.head.clone(),
            base: TRUNK.into(),
            main: if self.behind > 0 {
                ADVANCED_TRUNK
            } else {
                TRUNK
            }
            .into(),
            publication,
            passed,
            parent_landed: true,
            landed_onto: None,
        };
        let state = if matches!(self.owner.as_str(), "delivered" | "discarded") {
            State::released(Workspace::Main, self.owner == "delivered")
        } else if self.landed {
            State::delivered()
        } else if !self.conflicts.is_empty() {
            State::conflicted()
        } else if self.lint_passed {
            State::validated()
        } else {
            State::editing()
        };
        topic.restore(state)
    }

    pub fn classify(&self) -> Classification {
        let machine = self.machine();
        let stage = self.stage(&machine);
        Classification {
            stage,
            next: self.next(stage),
            allowed: allowed(&machine),
        }
    }

    fn stage(&self, machine: &Machine) -> Stage {
        let topic = machine.inner();
        match machine.state() {
            State::Released { .. } => return Stage::Finished,
            _ if self.stranded.is_some() => return Stage::Stranded,
            State::Delivered { .. } => return Stage::Landed,
            _ if self.idle => return Stage::Idle,
            _ => {}
        }
        if let Some(publication) = &topic.publication {
            return if publication.head != topic.head {
                Stage::Republish
            } else if topic.passed.as_ref() == Some(&topic.head) {
                Stage::Passed
            } else if self.spindle.as_deref() == Some("failed") {
                Stage::Failed
            } else {
                Stage::Published
            };
        }
        match machine.state() {
            State::Validated { .. } => Stage::Validated,
            _ => Stage::Editing,
        }
    }

    fn next(&self, stage: Stage) -> String {
        if !self.conflicts.is_empty() {
            return "resolve the conflicts oldest first (`ci conflicts` lists them), then `ci preflight`".into();
        }
        match stage {
            Stage::Stranded => {
                let s = self
                    .stranded
                    .as_ref()
                    .expect("a stranded stage has a stranded topic");
                format!(
                    "the working copy left this workspace's topic {} \"{}\"; return with `jj edit {}` and `jj abandon {}`",
                    s.short, s.title, s.short, s.stray
                )
            }
            Stage::Finished => "archive this task; start a new task for further work".into(),
            Stage::Landed => "run `ci park` to confirm delivery and free the workspace".into(),
            Stage::Idle => "edit files to start the topic, or `ci park` if it was delivered".into(),
            Stage::Editing if !self.described => {
                "describe the change with an `Impact:` trailer, then `ci preflight`".into()
            }
            Stage::Editing => "run `ci preflight`, then `ci dispatch`".into(),
            Stage::Validated => "run `ci dispatch`".into(),
            Stage::Republish => {
                "the head moved since dispatch; run `ci dispatch` to update the branch".into()
            }
            Stage::Published => {
                "run `ci land` when the topic is ready to deliver; it builds the checks locally"
                    .into()
            }
            Stage::Passed => "run `ci land` when the topic is ready to deliver".into(),
            Stage::Failed => {
                "inspect the failed pipeline, fix the topic, and `ci dispatch` again".into()
            }
        }
    }
}

/// The protocol steps the machine accepts, tried on a copy of it.
fn allowed(machine: &Machine) -> Vec<&'static str> {
    let steps = [
        (
            "rebase",
            Event::Rebase {
                head: "rebased".into(),
                conflicted: false,
            },
        ),
        ("resolve", Event::Resolve),
        ("validate", Event::Validate),
        ("publish", Event::Publish),
        ("land", Event::Land),
        (
            "finish",
            Event::Finish {
                workspace: Workspace::Main,
            },
        ),
        (
            "abandon",
            Event::Abandon {
                workspace: Workspace::Main,
            },
        ),
    ];
    steps
        .into_iter()
        .filter(|(_, event)| apply(&mut machine.clone(), event))
        .map(|(name, _)| name)
        .collect()
}
