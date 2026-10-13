//! Every workspace's topic, read from the JJ graph and the records `ci` keeps
//! under each workspace's `.jj`, and classified by the lifecycle machine.
//!
//! JJ runs with `--ignore-working-copy`, so the tower never snapshots another
//! session's working copy: it sees each workspace as of its last JJ command.
//! Three JJ processes read everything: the workspace list, the graph above
//! trunk, and trunk's recent history.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Instant;

use jj_ci_lifecycle::stage::{Observation, Stage, Stranded};
use serde::{Deserialize, Serialize};

use crate::time;

/// The trunk revset `context-status` uses.
pub const TRUNK: &str = r#"coalesce(remote_bookmarks(exact:"main", exact:"tangled"), trunk())"#;
const TRUNK_REMOTE: &str = "tangled";
/// How much trunk history to read; a topic further behind shows as `≥N`.
pub const TRUNK_DEPTH: usize = 300;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Revision {
    pub commit_id: String,
    pub change_id: String,
    pub short: String,
    #[serde(skip)]
    pub parents: Vec<String>,
    pub title: String,
    pub described: bool,
    pub empty: bool,
    pub conflict: bool,
    pub divergent: bool,
    pub impact: Vec<String>,
    #[serde(skip)]
    pub remote_bookmarks: Vec<(String, String)>,
    #[serde(skip)]
    pub on_trunk: bool,
    pub time_ms: i64,
}

#[derive(Deserialize)]
struct RawRevision {
    c: String,
    ch: String,
    s: String,
    p: Vec<String>,
    t: String,
    d: bool,
    e: bool,
    x: bool,
    dv: bool,
    i: Vec<String>,
    rb: Vec<(String, String)>,
    on: bool,
    ts: i64,
}

impl From<RawRevision> for Revision {
    fn from(raw: RawRevision) -> Self {
        Revision {
            commit_id: raw.c,
            change_id: raw.ch,
            short: raw.s,
            parents: raw.p,
            title: raw.t,
            described: raw.d,
            empty: raw.e,
            conflict: raw.x,
            divergent: raw.dv,
            impact: raw.i,
            remote_bookmarks: raw.rb,
            on_trunk: raw.on,
            time_ms: raw.ts * 1_000,
        }
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct TrunkCommit {
    pub commit_id: String,
    pub short: String,
    pub title: String,
    pub impact: Vec<String>,
    pub tags: Vec<String>,
    pub author: String,
    pub time_ms: i64,
}

#[derive(Deserialize)]
struct RawTrunk {
    c: String,
    s: String,
    t: String,
    i: Vec<String>,
    tags: Vec<String>,
    a: String,
    ts: i64,
}

#[derive(Clone, Debug, Deserialize)]
struct RawWorkspace {
    name: String,
    /// JJ forgets the root of a workspace whose directory it lost track of.
    root: Option<String>,
    c: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "state", rename_all = "lowercase")]
pub enum Lint {
    Passed { at_ms: Option<i64> },
    Stale,
    Never,
}

/// The pipeline facts `context-status` caches for the dispatched head.
#[derive(Clone, Debug, Default, Serialize)]
pub struct CiCache {
    pub spindle: Option<String>,
    pub github: Option<String>,
    pub pull: Option<String>,
    pub checked_ms: Option<i64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Topic {
    /// Stable identity for selection: the workspace, or the branch.
    pub key: String,
    pub workspace: Option<String>,
    pub root: Option<PathBuf>,
    pub current: bool,
    pub head: Revision,
    /// Oldest first.
    pub stack: Vec<Revision>,
    pub idle: bool,
    pub behind: Option<usize>,
    pub branch: Option<String>,
    pub published_head: Option<String>,
    pub landed: bool,
    pub owner: String,
    pub lint: Lint,
    pub ci: Option<CiCache>,
    pub stranded: Option<StrandedTopic>,
    pub reviews: Vec<String>,
    pub stage: Stage,
    pub next: String,
    pub allowed: Vec<&'static str>,
    pub conflicts: Vec<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StrandedTopic {
    pub short: String,
    pub title: String,
    pub stray: String,
}

impl Topic {
    /// The topic's combined Impact class, as `ci dispatch` would judge it.
    pub fn impact(&self) -> Option<String> {
        if self.stack.is_empty() {
            return None;
        }
        let mut classes: HashSet<&str> = HashSet::new();
        for revision in &self.stack {
            match revision.impact.last() {
                Some(impact) => {
                    classes.insert(impact.as_str());
                }
                None => return Some("unclassified".into()),
            }
        }
        let user_facing = classes.contains("behavior") || classes.contains("breaking");
        if classes.contains("refactor") && user_facing {
            Some("mixed".into())
        } else if classes.contains("breaking") {
            Some("breaking".into())
        } else if classes.contains("behavior") {
            Some("behavior".into())
        } else {
            classes.into_iter().next().map(str::to_string)
        }
    }

    pub fn dispatched(&self) -> bool {
        self.published_head.is_some()
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct Snapshot {
    pub repo: PathBuf,
    pub trunk: Vec<TrunkCommit>,
    pub topics: Vec<Topic>,
    pub workspace_roots: Vec<PathBuf>,
    pub op_heads: Option<PathBuf>,
    pub taken_ms: i64,
    pub took_ms: u64,
}

pub fn jj(repo: &Path, args: &[&str]) -> Result<String, String> {
    let mut attempt = 0;
    loop {
        attempt += 1;
        let output = Command::new("jj")
            .args([
                "--ignore-working-copy",
                "--no-pager",
                "--color",
                "never",
                "-R",
            ])
            .arg(repo)
            .args(args)
            .output()
            .map_err(|error| format!("could not run jj: {error}"))?;
        if output.status.success() {
            return String::from_utf8(output.stdout).map_err(|error| error.to_string());
        }
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        // Another JJ process replacing the operation heads mid-read fails
        // before changing anything; ci retries it the same way.
        if attempt < 3 && stderr.contains("operation heads") {
            std::thread::sleep(std::time::Duration::from_millis(300 * attempt));
            continue;
        }
        return Err(stderr.lines().last().unwrap_or("jj failed").to_string());
    }
}

fn read_json(path: &Path) -> Option<serde_json::Value> {
    let text = std::fs::read_to_string(path).ok()?;
    serde_json::from_str(&text).ok()
}

fn str_field(value: &serde_json::Value, key: &str) -> Option<String> {
    value.get(key)?.as_str().map(str::to_string)
}

/// The owner state a Codex ownership record declares, as ci's owner-status.
fn owner_status(record: &serde_json::Value) -> String {
    let state = str_field(record, "state").unwrap_or_default();
    if matches!(
        state.as_str(),
        "active" | "delivered" | "discarded" | "released"
    ) {
        return state;
    }
    if record.get("finished").and_then(|v| v.as_bool()) == Some(true) {
        "released".into()
    } else {
        "active".into()
    }
}

/// The repository's shared `op_heads/heads` directory, whose changes mark
/// every JJ operation in any workspace.
pub fn op_heads_dir(workspace_root: &Path) -> Option<PathBuf> {
    let pointer = workspace_root.join(".jj").join("repo");
    let repo = if pointer.is_file() {
        let target = std::fs::read_to_string(&pointer).ok()?;
        workspace_root.join(".jj").join(target.trim())
    } else {
        pointer
    };
    let heads = repo.join("op_heads").join("heads");
    heads
        .is_dir()
        .then(|| heads.canonicalize().unwrap_or(heads))
}

/// The JJ workspace root at or above `dir`.
pub fn workspace_root(dir: &Path) -> Option<PathBuf> {
    let mut current = dir.canonicalize().ok()?;
    loop {
        if current.join(".jj").is_dir() {
            return Some(current);
        }
        if !current.pop() {
            return None;
        }
    }
}

fn revision_template() -> String {
    let trunk = TRUNK.replace('"', "\\\"");
    [
        r#""{\"c\":\"" ++ commit_id ++ "\",\"ch\":\"" ++ change_id ++ "\",\"s\":" ++ json(change_id.short(8))"#,
        r#" ++ ",\"p\":[" ++ parents.map(|p| "\"" ++ p.commit_id() ++ "\"").join(",") ++ "]""#,
        r#" ++ ",\"t\":" ++ json(description.first_line()) ++ ",\"d\":" ++ json(description != "")"#,
        r#" ++ ",\"e\":" ++ json(empty) ++ ",\"x\":" ++ json(conflict) ++ ",\"dv\":" ++ json(divergent)"#,
        r#" ++ ",\"i\":" ++ json(trailers.filter(|t| t.key() == "Impact").map(|t| t.value()))"#,
        r#" ++ ",\"rb\":[" ++ remote_bookmarks.map(|b| "[" ++ json(b.name()) ++ "," ++ json(b.remote()) ++ "]").join(",") ++ "]""#,
        &format!(r#" ++ ",\"on\":" ++ json(self.contained_in("::{trunk}"))"#),
        r#" ++ ",\"ts\":" ++ committer.timestamp().format("%s") ++ "}\n""#,
    ]
    .concat()
}

const TRUNK_TEMPLATE: &str = r#""{\"c\":\"" ++ commit_id ++ "\",\"s\":" ++ json(change_id.short(8)) ++ ",\"t\":" ++ json(description.first_line()) ++ ",\"i\":" ++ json(trailers.filter(|t| t.key() == "Impact").map(|t| t.value())) ++ ",\"tags\":[" ++ tags.map(|t| json(t.name())).join(",") ++ "],\"a\":" ++ json(author.name()) ++ ",\"ts\":" ++ committer.timestamp().format("%s") ++ "}\n""#;

const WORKSPACE_TEMPLATE: &str = r#""{\"name\":" ++ json(self.name()) ++ ",\"root\":" ++ json(self.root()) ++ ",\"c\":\"" ++ self.target().commit_id() ++ "\"}\n""#;

fn parse_lines<T: for<'de> Deserialize<'de>>(text: &str) -> Result<Vec<T>, String> {
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .map(|line| {
            serde_json::from_str(line).map_err(|error| format!("unreadable jj output: {error}"))
        })
        .collect()
}

/// Files `ci` and its hooks keep in a workspace's `.jj`.
#[derive(Default)]
struct WorkspaceRecords {
    owner: Option<serde_json::Value>,
    publication: HashMap<String, String>,
    validation: Option<(String, Option<i64>)>,
    cache: Option<serde_json::Value>,
    recorded_topic: Option<String>,
    reviews: Vec<String>,
}

fn workspace_records(root: &Path) -> WorkspaceRecords {
    let dir = root.join(".jj");
    let publication = read_json(&dir.join("jj-ci-publication.json"))
        .and_then(|value| value.get("topics").cloned())
        .and_then(|topics| serde_json::from_value(topics).ok())
        .unwrap_or_default();
    let validation = read_json(&dir.join("jj-ci-validation.json")).and_then(|value| {
        let commit = str_field(&value, "commit_id")?;
        let at = str_field(&value, "validated_at").and_then(|at| time::parse(&at));
        Some((commit, at))
    });
    let reviews = read_json(&dir.join("jj-ci-review-versions.json"))
        .and_then(|value| value.as_array().cloned())
        .map(|entries| {
            entries
                .iter()
                .filter_map(|entry| str_field(entry, "label"))
                .collect()
        })
        .unwrap_or_default();
    WorkspaceRecords {
        owner: read_json(&dir.join("codex-session.json")),
        publication,
        validation,
        cache: read_json(&dir.join("context-status.json")),
        recorded_topic: read_json(&dir.join("jj-ci-workspace.json"))
            .and_then(|value| str_field(&value, "change_id")),
        reviews,
    }
}

/// The files under each workspace's `.jj` whose change should refresh the
/// board even without a JJ operation, such as a preflight record.
pub fn record_files(root: &Path) -> [PathBuf; 6] {
    let dir = root.join(".jj");
    [
        "codex-session.json",
        "jj-ci-publication.json",
        "jj-ci-validation.json",
        "context-status.json",
        "jj-ci-workspace.json",
        "jj-ci-review-versions.json",
    ]
    .map(|name| dir.join(name))
}

struct Graph {
    revisions: HashMap<String, Revision>,
    trunk_index: HashMap<String, usize>,
    by_change: HashMap<String, Vec<String>>,
    remote_heads: HashMap<String, String>,
}

impl Graph {
    /// The revisions above trunk reachable from `tip`, oldest first, and how
    /// far behind trunk their base is.
    fn stack(&self, tip: &str) -> (Vec<Revision>, Option<usize>) {
        let mut seen = HashSet::new();
        let mut order = Vec::new();
        let mut bases = Vec::new();
        let mut pending = vec![tip.to_string()];
        while let Some(commit) = pending.pop() {
            if !seen.insert(commit.clone()) {
                continue;
            }
            match self.revisions.get(&commit) {
                Some(revision) if !revision.on_trunk => {
                    order.push(revision.clone());
                    pending.extend(revision.parents.iter().cloned());
                }
                _ => bases.push(commit),
            }
        }
        order.reverse();
        let behind = bases
            .iter()
            .filter_map(|base| self.trunk_index.get(base))
            .min()
            .copied();
        (order, behind)
    }
}

fn graph(repo: &Path, recorded: &[String]) -> Result<(Graph, Vec<TrunkCommit>), String> {
    let mut heads =
        format!(r#"working_copies() | remote_bookmarks(glob:"jj-*", exact:"{TRUNK_REMOTE}")"#);
    for change in recorded {
        if change.bytes().all(|b| b.is_ascii_lowercase()) {
            heads.push_str(&format!(" | present(change_id({change}))"));
        }
    }
    let revset = format!("({TRUNK})..({heads}) | ({heads})");
    let template = revision_template();
    let revisions: Vec<Revision> = parse_lines::<RawRevision>(&jj(
        repo,
        &["log", "--no-graph", "-r", &revset, "-T", &template],
    )?)?
    .into_iter()
    .map(Revision::from)
    .collect();
    let trunk_revset = format!("ancestors({TRUNK}, {TRUNK_DEPTH})");
    let trunk: Vec<TrunkCommit> = parse_lines::<RawTrunk>(&jj(
        repo,
        &[
            "log",
            "--no-graph",
            "-r",
            &trunk_revset,
            "-T",
            TRUNK_TEMPLATE,
        ],
    )?)?
    .into_iter()
    .map(|raw| TrunkCommit {
        commit_id: raw.c,
        short: raw.s,
        title: raw.t,
        impact: raw.i,
        tags: raw.tags,
        author: raw.a,
        time_ms: raw.ts * 1_000,
    })
    .collect();
    let trunk_index = trunk
        .iter()
        .enumerate()
        .map(|(index, commit)| (commit.commit_id.clone(), index))
        .collect();
    let mut by_change: HashMap<String, Vec<String>> = HashMap::new();
    let mut remote_heads = HashMap::new();
    for revision in &revisions {
        by_change
            .entry(revision.change_id.clone())
            .or_default()
            .push(revision.commit_id.clone());
        for (name, remote) in &revision.remote_bookmarks {
            if remote == TRUNK_REMOTE && name.starts_with("jj-") {
                remote_heads.insert(name.clone(), revision.commit_id.clone());
            }
        }
    }
    let revisions = revisions
        .into_iter()
        .map(|revision| (revision.commit_id.clone(), revision))
        .collect();
    Ok((
        Graph {
            revisions,
            trunk_index,
            by_change,
            remote_heads,
        },
        trunk,
    ))
}

fn stage_order(stage: Stage) -> u8 {
    match stage {
        Stage::Failed => 0,
        Stage::Stranded => 1,
        Stage::Republish => 2,
        Stage::Passed => 3,
        Stage::Published => 4,
        Stage::Validated => 5,
        Stage::Editing => 6,
        Stage::Landed => 7,
        Stage::Finished => 8,
        Stage::Idle => 9,
    }
}

struct TopicFacts {
    key: String,
    workspace: Option<String>,
    root: Option<PathBuf>,
    current: bool,
    wc: Option<Revision>,
    stack: Vec<Revision>,
    behind: Option<usize>,
    branch: Option<String>,
    records: WorkspaceRecords,
}

fn classify(graph: &Graph, facts: TopicFacts) -> Option<Topic> {
    let TopicFacts {
        key,
        workspace,
        root,
        current,
        wc,
        stack,
        behind,
        branch,
        records,
    } = facts;
    let head = stack.last().cloned().or_else(|| wc.clone())?;
    let idle = stack.is_empty();
    let owner_record = records.owner.as_ref().filter(|record| {
        let change = str_field(record, "change_id");
        change.as_deref() == Some(head.change_id.as_str())
            || wc
                .as_ref()
                .is_some_and(|wc| change.as_deref() == Some(wc.change_id.as_str()))
    });
    let owner = owner_record
        .map(owner_status)
        .unwrap_or_else(|| "none".into());
    let branch = branch.or_else(|| records.publication.get(&head.change_id).cloned());
    let published_head = branch
        .as_ref()
        .and_then(|branch| graph.remote_heads.get(branch).cloned());
    let landed = published_head
        .as_ref()
        .is_some_and(|commit| graph.revisions.get(commit).is_some_and(|r| r.on_trunk));
    let lint = match &records.validation {
        Some((commit, at)) if *commit == head.commit_id => Lint::Passed { at_ms: *at },
        Some(_) => Lint::Stale,
        None => Lint::Never,
    };
    let ci = records.cache.as_ref().and_then(|cache| {
        let state = cache.get("state")?;
        if str_field(state, "published_head")? != *published_head.as_ref()? {
            return None;
        }
        let verdict = |name: &str| {
            state
                .get(name)
                .and_then(|v| v.get("state"))
                .and_then(|v| v.as_str())
                .map(str::to_string)
        };
        Some(CiCache {
            spindle: verdict("spindle"),
            github: verdict("github"),
            pull: str_field(state, "pull"),
            checked_ms: str_field(cache, "checked_at").and_then(|at| time::parse(&at)),
        })
    });
    let stranded = wc.as_ref().and_then(|wc| {
        let recorded = records.recorded_topic.as_ref()?;
        if stack.iter().any(|r| &r.change_id == recorded) || !wc.empty {
            return None;
        }
        let topic = graph
            .by_change
            .get(recorded)?
            .iter()
            .find_map(|commit| graph.revisions.get(commit))?;
        let topic_empty = topic.empty && !topic.described;
        (!topic.on_trunk && !topic_empty && &wc.change_id != recorded).then(|| StrandedTopic {
            short: topic.short.clone(),
            title: topic.title.clone(),
            stray: wc.short.clone(),
        })
    });
    let conflicts: Vec<String> = stack
        .iter()
        .filter(|r| r.conflict)
        .map(|r| r.short.clone())
        .collect();
    let observation = Observation {
        owner: owner.clone(),
        stranded: stranded.as_ref().map(|s| Stranded {
            short: s.short.clone(),
            title: s.title.clone(),
            stray: s.stray.clone(),
        }),
        landed,
        idle,
        head: head.commit_id.clone(),
        described: head.described,
        behind: behind.unwrap_or(0) as u64,
        published_head: published_head.clone(),
        spindle: ci.as_ref().and_then(|ci| ci.spindle.clone()),
        lint_passed: matches!(lint, Lint::Passed { .. }),
        conflicts: conflicts.clone(),
    };
    let classification = observation.classify();
    Some(Topic {
        key,
        workspace,
        root,
        current,
        head,
        stack,
        idle,
        behind,
        branch,
        published_head,
        landed,
        owner,
        lint,
        ci,
        stranded,
        reviews: records.reviews,
        stage: classification.stage,
        next: classification.next,
        allowed: classification.allowed,
        conflicts,
    })
}

/// Reads every topic in the repository that holds `dir`.
pub fn snapshot(dir: &Path) -> Result<Snapshot, String> {
    let started = Instant::now();
    let here = workspace_root(dir);
    let repo = here.clone().unwrap_or_else(|| dir.to_path_buf());
    let workspaces: Vec<(RawWorkspace, String)> = parse_lines::<RawWorkspace>(&jj(
        &repo,
        &["workspace", "list", "-T", WORKSPACE_TEMPLATE],
    )?)?
    .into_iter()
    .filter_map(|ws| {
        let root = ws.root.clone()?;
        Some((ws, root))
    })
    .collect();
    let records: Vec<WorkspaceRecords> = workspaces
        .iter()
        .map(|(_, root)| workspace_records(Path::new(root)))
        .collect();
    let recorded: Vec<String> = records
        .iter()
        .filter_map(|r| r.recorded_topic.clone())
        .collect();
    let (graph, trunk) = graph(&repo, &recorded)?;

    let mut topics = Vec::new();
    let mut claimed_branches = HashSet::new();
    let mut claimed_commits = HashSet::new();
    for ((workspace, root), records) in workspaces.iter().zip(records) {
        let wc = graph.revisions.get(&workspace.c).cloned();
        let (mut stack, behind) = graph.stack(&workspace.c);
        // An empty, undescribed working copy is scratch space above the topic.
        if wc
            .as_ref()
            .is_some_and(|wc| wc.empty && !wc.described && !wc.on_trunk)
        {
            stack.retain(|revision| revision.commit_id != workspace.c);
        }
        claimed_commits.extend(stack.iter().map(|r| r.commit_id.clone()));
        let root = PathBuf::from(root);
        let facts = TopicFacts {
            key: format!("ws:{}", workspace.name),
            workspace: Some(workspace.name.clone()),
            current: here.as_ref() == Some(&root),
            root: Some(root),
            wc,
            stack,
            behind,
            branch: None,
            records,
        };
        if let Some(topic) = classify(&graph, facts) {
            if let Some(branch) = &topic.branch {
                claimed_branches.insert(branch.clone());
            }
            topics.push(topic);
        }
    }

    // Dispatched topics no workspace has checked out, such as one dispatched
    // from another machine or left behind by a removed workspace.
    let mut orphans: Vec<(&String, &String)> = graph.remote_heads.iter().collect();
    orphans.sort();
    for (branch, commit) in orphans {
        let landed = graph.revisions.get(commit).is_none_or(|r| r.on_trunk);
        if landed || claimed_branches.contains(branch) || claimed_commits.contains(commit) {
            continue;
        }
        let (stack, behind) = graph.stack(commit);
        let facts = TopicFacts {
            key: format!("branch:{branch}"),
            workspace: None,
            root: None,
            current: false,
            wc: None,
            stack,
            behind,
            branch: Some(branch.clone()),
            records: WorkspaceRecords::default(),
        };
        topics.extend(classify(&graph, facts));
    }

    topics.sort_by(|a, b| {
        (
            stage_order(a.stage),
            std::cmp::Reverse(a.head.time_ms),
            &a.key,
        )
            .cmp(&(
                stage_order(b.stage),
                std::cmp::Reverse(b.head.time_ms),
                &b.key,
            ))
    });
    let workspace_roots = workspaces
        .iter()
        .map(|(_, root)| PathBuf::from(root))
        .collect();
    Ok(Snapshot {
        op_heads: op_heads_dir(&repo),
        repo,
        trunk,
        topics,
        workspace_roots,
        taken_ms: time::now_ms(),
        took_ms: started.elapsed().as_millis() as u64,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn revision(commit: &str, parents: &[&str], on_trunk: bool) -> Revision {
        Revision {
            commit_id: commit.into(),
            change_id: format!("change-{commit}"),
            short: commit.into(),
            parents: parents.iter().map(|p| p.to_string()).collect(),
            title: commit.into(),
            described: true,
            empty: false,
            conflict: false,
            divergent: false,
            impact: vec!["refactor".into()],
            remote_bookmarks: vec![],
            on_trunk,
            time_ms: 0,
        }
    }

    #[test]
    fn a_stack_reaches_its_trunk_base() {
        let revisions = [revision("b", &["a"], false), revision("a", &["t2"], false)];
        let graph = Graph {
            revisions: revisions
                .into_iter()
                .map(|r| (r.commit_id.clone(), r))
                .collect(),
            trunk_index: [("t0", 0), ("t1", 1), ("t2", 2)]
                .map(|(c, i)| (c.to_string(), i))
                .into(),
            by_change: HashMap::new(),
            remote_heads: HashMap::new(),
        };
        let (stack, behind) = graph.stack("b");
        assert_eq!(
            stack
                .iter()
                .map(|r| r.commit_id.as_str())
                .collect::<Vec<_>>(),
            ["a", "b"]
        );
        assert_eq!(behind, Some(2));
        // A working copy on trunk itself has an empty stack.
        assert_eq!(graph.stack("t1"), (vec![], Some(1)));
    }

    #[test]
    fn impact_combines_like_dispatch() {
        let mut topic_stack = vec![revision("a", &[], false), revision("b", &["a"], false)];
        let make = |stack: Vec<Revision>| Topic {
            key: "k".into(),
            workspace: None,
            root: None,
            current: false,
            head: stack.last().unwrap().clone(),
            stack,
            idle: false,
            behind: None,
            branch: None,
            published_head: None,
            landed: false,
            owner: "none".into(),
            lint: Lint::Never,
            ci: None,
            stranded: None,
            reviews: vec![],
            stage: Stage::Editing,
            next: String::new(),
            allowed: vec![],
            conflicts: vec![],
        };
        assert_eq!(
            make(topic_stack.clone()).impact().as_deref(),
            Some("refactor")
        );
        topic_stack[1].impact = vec!["behavior".into()];
        assert_eq!(make(topic_stack.clone()).impact().as_deref(), Some("mixed"));
        topic_stack[0].impact = vec![];
        assert_eq!(make(topic_stack).impact().as_deref(), Some("unclassified"));
    }
}
