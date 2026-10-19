//! Machine-wide facts: the locks `ci` holds while it moves a topic or runs
//! the local checks, and which releases this host activated and verified.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::Serialize;

use crate::jobs::{home, state_home};
use crate::time;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Holder {
    /// `change "title"`, as ci's lock-topic writes it.
    pub topic: String,
    pub pid: i32,
    pub workspace: String,
    pub unit: Option<String>,
    pub since_ms: Option<i64>,
}

impl Holder {
    /// The change id the lock names, without its title.
    pub fn change(&self) -> &str {
        self.topic.split_whitespace().next().unwrap_or("")
    }

    pub fn title(&self) -> &str {
        self.topic
            .split_once(' ')
            .map(|(_, title)| title.trim().trim_matches('"'))
            .unwrap_or("")
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Locks {
    /// Who runs the machine's flake checks or a refactor's closure proof.
    pub checks: Option<Holder>,
    /// Topics being dispatched or landed, by full change id.
    pub topics: Vec<(String, Holder)>,
    /// The runway, front first: the landing that may move main, then those
    /// waiting behind it.
    pub landing: Vec<Holder>,
    /// Topics `ci queue` held for the drainer, in landing order.
    pub held: Vec<Held>,
}

/// A topic held for the drainer: ci's hold-topic record, with its place in
/// the line from ci's landing-plan.json.
#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Held {
    /// `change "title"`, as ci's lock-topic writes it.
    pub topic: String,
    /// The full change id, which `ci queue move --change` takes.
    pub change_id: String,
    pub workspace: String,
    pub since_ms: Option<i64>,
    /// The flight it lands in, counting from 1; one flight is one train.
    pub flight: Option<u64>,
    /// Why it holds its place: arrival, moved by hand, stacked on a parent.
    pub reason: Option<String>,
}

impl Held {
    pub fn change(&self) -> &str {
        self.topic.split_whitespace().next().unwrap_or("")
    }

    pub fn title(&self) -> &str {
        self.topic
            .split_once(' ')
            .map(|(_, title)| title.trim().trim_matches('"'))
            .unwrap_or("")
    }
}

/// The JSON tickets in `dir`, named by their number, lowest first, as ci's
/// draw-ticket writes them.
fn tickets(dir: &Path) -> Vec<PathBuf> {
    let mut tickets: Vec<(u64, PathBuf)> = fs::read_dir(dir)
        .map(|entries| {
            entries
                .filter_map(|e| e.ok())
                .map(|e| e.path())
                .filter(|p| p.extension().is_some_and(|x| x == "json"))
                .filter_map(|p| Some((p.file_stem()?.to_str()?.parse().ok()?, p)))
                .collect()
        })
        .unwrap_or_default();
    tickets.sort();
    tickets.into_iter().map(|(_, p)| p).collect()
}

fn held(path: &Path) -> Option<Held> {
    let value: serde_json::Value = serde_json::from_str(&fs::read_to_string(path).ok()?).ok()?;
    let field = |key: &str| value.get(key).and_then(|v| v.as_str());
    Some(Held {
        topic: field("topic")?.to_string(),
        change_id: field("change").unwrap_or("").to_string(),
        workspace: field("workspace").unwrap_or("").to_string(),
        since_ms: field("held_at").and_then(time::parse),
        flight: None,
        reason: None,
    })
}

/// Put `held`, in ticket order, in the order of ci's line, `plan` (the rows
/// of landing-plan.json), with each one's flight and reason. ci writes the
/// plan whenever it reads or changes the line; a hold it has not planned
/// yet keeps its ticket order after the planned ones.
fn order_held(mut held: Vec<Held>, plan: &[serde_json::Value]) -> Vec<Held> {
    let place = |change: &str| {
        plan.iter()
            .position(|row| row.get("change").and_then(|c| c.as_str()) == Some(change))
    };
    for hold in &mut held {
        if let Some(row) = place(&hold.change_id).map(|index| &plan[index]) {
            hold.flight = row.get("flight").and_then(|f| f.as_u64());
            hold.reason = row
                .get("reason")
                .and_then(|r| r.as_str())
                .map(str::to_string);
        }
    }
    // A stable sort keeps unplanned holds in ticket order.
    held.sort_by_key(|hold| place(&hold.change_id).unwrap_or(usize::MAX));
    held
}

/// A process's start time in clock ticks since boot, as ci's process-start.
fn process_start(pid: i32) -> Option<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    let after = stat.rsplit_once(')')?.1;
    after.split_whitespace().nth(19).map(str::to_string)
}

fn unit_active(unit: &str) -> bool {
    Command::new("systemctl")
        .args(["--user", "is-active", "--quiet", unit])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// The live holder of a lock file, as ci's lock-holder-alive decides.
fn holder(path: &Path, units: &mut HashMap<String, (bool, i64)>) -> Option<Holder> {
    let text = fs::read_to_string(path).ok()?;
    let value: serde_json::Value = serde_json::from_str(&text).ok()?;
    let pid = value.get("pid")?.as_i64()? as i32;
    let start = value.get("start").and_then(|s| s.as_str());
    let unit = value
        .get("unit")
        .and_then(|u| u.as_str())
        .map(str::to_string);
    let alive = start.is_some() && process_start(pid).as_deref() == start;
    let alive = alive
        || unit.as_ref().is_some_and(|unit| {
            // systemctl costs a process, so its answer holds for a while.
            let now = time::now_ms();
            match units.get(unit) {
                Some((active, at)) if now - at < 5_000 => *active,
                _ => {
                    let active = unit_active(unit);
                    units.insert(unit.clone(), (active, now));
                    active
                }
            }
        });
    if !alive {
        return None;
    }
    let since_ms = fs::metadata(path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as i64);
    Some(Holder {
        topic: value
            .get("topic")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string(),
        pid,
        workspace: value
            .get("workspace")
            .and_then(|w| w.as_str())
            .unwrap_or("")
            .to_string(),
        unit,
        since_ms,
    })
}

#[derive(Default)]
pub struct LockReader {
    units: HashMap<String, (bool, i64)>,
}

impl LockReader {
    pub fn read(&mut self) -> Locks {
        let dir = state_home().join("jj-ci");
        let checks = holder(&dir.join("local-checks.lock"), &mut self.units);
        let mut topics: Vec<(String, Holder)> = fs::read_dir(dir.join("topics"))
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.extension().is_some_and(|x| x == "lock"))
                    .filter_map(|p| {
                        let change = p.file_stem()?.to_string_lossy().into_owned();
                        Some((change, holder(&p, &mut self.units)?))
                    })
                    .collect()
            })
            .unwrap_or_default();
        topics.sort_by(|a, b| a.0.cmp(&b.0));
        // ci keeps its runway tickets in landing-queue, and its holds in
        // landing-holds.
        let landing = tickets(&dir.join("landing-queue"))
            .iter()
            .filter_map(|p| holder(p, &mut self.units))
            .collect();
        let held = tickets(&dir.join("landing-holds"))
            .iter()
            .filter_map(|p| held(p))
            .collect();
        let plan: Vec<serde_json::Value> = fs::read_to_string(dir.join("landing-plan.json"))
            .ok()
            .and_then(|text| serde_json::from_str(&text).ok())
            .unwrap_or_default();
        let held = order_held(held, &plan);
        Locks {
            checks,
            topics,
            landing,
            held,
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct HostInfo {
    pub hostname: String,
    /// Release to when this host verified it.
    pub verified: HashMap<String, i64>,
    /// Verifications not yet sent to homelab.
    pub queued: usize,
    pub activated_ms: Option<i64>,
    pub running: Option<PathBuf>,
}

fn jsonl(path: &Path) -> Vec<serde_json::Value> {
    fs::read_to_string(path)
        .map(|text| {
            text.lines()
                .filter_map(|line| serde_json::from_str(line).ok())
                .collect()
        })
        .unwrap_or_default()
}

pub fn host_info() -> HostInfo {
    let hostname = fs::read_to_string("/proc/sys/kernel/hostname")
        .unwrap_or_default()
        .trim()
        .to_string();
    let dir = state_home().join("config-verifications");
    let mut verified = HashMap::new();
    for record in jsonl(&dir.join("verified.jsonl")) {
        let field = |key: &str| record.get(key).and_then(|v| v.as_str());
        if field("host") != Some(hostname.as_str()) {
            continue;
        }
        if let (Some(release), Some(at)) =
            (field("release"), field("verified_at").and_then(time::parse))
        {
            verified.insert(release.to_string(), at);
        }
    }
    let queued = jsonl(&dir.join("outbox.jsonl")).len();
    let running = fs::canonicalize("/run/current-system").ok();
    let activated_ms = jsonl(Path::new("/var/log/nixos-activations.jsonl"))
        .iter()
        .rev()
        .find(|record| {
            running.as_ref().is_some_and(|running| {
                record.get("toplevel").and_then(|t| t.as_str())
                    == Some(running.to_string_lossy().as_ref())
            })
        })
        .and_then(|record| {
            record
                .get("time")
                .and_then(|t| t.as_str())
                .and_then(time::parse)
        });
    HostInfo {
        hostname,
        verified,
        queued,
        activated_ms,
        running,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hold(change: &str) -> Held {
        Held {
            topic: format!("{change} \"{change}\""),
            change_id: change.into(),
            workspace: String::new(),
            since_ms: None,
            flight: None,
            reason: None,
        }
    }

    #[test]
    fn held_topics_follow_the_line_ci_planned() {
        let plan: Vec<serde_json::Value> = serde_json::from_str(
            r#"[{"change": "kc", "flight": 1, "reason": "moved by hand"},
                {"change": "ka", "flight": 1, "reason": "arrival"},
                {"change": "kgone", "flight": 2, "reason": "arrival"}]"#,
        )
        .unwrap();
        let held = order_held(vec![hold("ka"), hold("kb"), hold("kc")], &plan);
        let changes: Vec<&str> = held.iter().map(|h| h.change_id.as_str()).collect();
        assert_eq!(changes, ["kc", "ka", "kb"], "unplanned holds go last");
        assert_eq!(held[0].reason.as_deref(), Some("moved by hand"));
        assert_eq!(held[1].flight, Some(1));
        assert_eq!(held[2].flight, None);
    }
}

/// `~` for the home directory, for shorter paths.
pub fn tilde(path: &Path) -> String {
    let home = home();
    match path.strip_prefix(&home) {
        Ok(rest) if rest.as_os_str().is_empty() => "~".into(),
        Ok(rest) => format!("~/{}", rest.display()),
        Err(_) => path.display().to_string(),
    }
}
