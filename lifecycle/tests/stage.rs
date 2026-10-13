//! The stages `context-status` shows, as the Nushell `lifecycle` derived them
//! before it asked the machine.

use jj_ci_lifecycle::stage::{Observation, Stage};
use serde_json::{json, Value};

fn observe(overrides: Value) -> Observation {
    let mut facts = json!({
        "owner": "active",
        "stranded": null,
        "landed": false,
        "idle": false,
        "head": "c1",
        "described": true,
        "behind": 0,
        "published_head": null,
        "spindle": null,
        "lint_passed": false,
        "conflicts": [],
    });
    for (key, value) in overrides.as_object().unwrap() {
        facts[key] = value.clone();
    }
    serde_json::from_value(facts).unwrap()
}

fn stage(overrides: Value) -> Stage {
    observe(overrides).classify().stage
}

#[test]
fn stages_follow_the_lifecycle() {
    assert_eq!(stage(json!({})), Stage::Editing);
    assert_eq!(stage(json!({ "lint_passed": true })), Stage::Validated);
    assert_eq!(stage(json!({ "published_head": "c1" })), Stage::Published);
    assert_eq!(stage(json!({ "published_head": "c0" })), Stage::Republish);
    assert_eq!(
        stage(json!({ "published_head": "c1", "spindle": "success" })),
        Stage::Passed
    );
    assert_eq!(
        stage(json!({ "published_head": "c1", "spindle": "failed" })),
        Stage::Failed
    );
    assert_eq!(
        stage(json!({ "published_head": "c0", "spindle": "success" })),
        Stage::Republish
    );
    assert_eq!(
        stage(json!({ "landed": true, "published_head": "c1" })),
        Stage::Landed
    );
    assert_eq!(stage(json!({ "idle": true })), Stage::Idle);
}

#[test]
fn ownership_and_stranding_come_first() {
    for owner in ["delivered", "discarded"] {
        assert_eq!(
            stage(json!({ "owner": owner, "landed": true })),
            Stage::Finished
        );
    }
    let stranded = json!({ "short": "abcdefgh", "title": "t", "stray": "zzzzzzzz" });
    assert_eq!(
        stage(json!({ "stranded": stranded, "landed": true })),
        Stage::Stranded
    );
}

#[test]
fn conflicts_lead_the_next_step() {
    let classification = observe(json!({ "conflicts": ["abcdefgh"] })).classify();
    assert!(classification.next.starts_with("resolve the conflicts"));
    assert_eq!(classification.allowed, ["resolve", "abandon"]);
}

#[test]
fn an_undescribed_topic_is_described_first() {
    let next = observe(json!({ "described": false })).classify().next;
    assert!(next.starts_with("describe the change"));
}

#[test]
fn allowed_steps_come_from_the_machine() {
    let allowed = |overrides| observe(overrides).classify().allowed;
    assert_eq!(
        allowed(json!({})),
        ["rebase", "validate", "finish", "abandon"]
    );
    assert_eq!(
        allowed(json!({ "lint_passed": true })),
        ["rebase", "validate", "publish", "finish", "abandon"]
    );
    // Publication needs the current trunk.
    assert_eq!(
        allowed(json!({ "lint_passed": true, "behind": 2 })),
        ["rebase", "validate", "finish", "abandon"]
    );
    assert_eq!(
        allowed(json!({ "published_head": "c1", "spindle": "success" })),
        ["rebase", "validate", "land"]
    );
    assert_eq!(
        allowed(json!({ "landed": true, "published_head": "c1" })),
        ["finish"]
    );
    assert_eq!(allowed(json!({ "owner": "delivered" })), Vec::<&str>::new());
}
