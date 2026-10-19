//! `ci` runs: the jobs the ci MCP server keeps under
//! `$XDG_STATE_HOME/ci-mcp/jobs`, and `job-log` jobs announced on
//! cross.stream. Each reports its phases as OSC 7501 records in a
//! `.status.jsonl` file beside its log, which `pst report` appends.
//!
//! The tower starts its own runs in the ci MCP server's layout, so agents
//! see them with the `jobs` and `job` tools, and `watch-job` follows them.

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};

use serde::Serialize;

use crate::time;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum RunState {
    Running,
    Succeeded,
    Failed,
    Lost,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum PhaseState {
    Working,
    Done,
    Error,
    /// Waiting on another session, such as the local checks lock.
    Blocked,
    /// Waiting on a person, such as an approval.
    Permission,
}

#[derive(Clone, Debug, Serialize)]
pub struct Phase {
    pub id: String,
    pub state: PhaseState,
    pub msg: String,
    pub started_ms: Option<i64>,
    pub ended_ms: Option<i64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Source {
    /// Started by the ci MCP server or the tower.
    Store,
    /// A `job-log` job in some session's scratchpad.
    Shell,
}

#[derive(Clone, Debug, Serialize)]
pub struct Run {
    pub id: String,
    pub source: Source,
    pub args: Vec<String>,
    pub workspace: PathBuf,
    pub log: PathBuf,
    pub status_file: PathBuf,
    pub started_ms: i64,
    pub ended_ms: Option<i64>,
    pub state: RunState,
    pub exit_code: Option<i32>,
    pub phases: Vec<Phase>,
    /// The run's own closing report, without a phase id.
    pub summary: Option<(PhaseState, String)>,
    pub mutating: bool,
    pub pid: Option<i32>,
}

impl Run {
    /// `land`, `dispatch`, ... for a store run; for a shell job, what its
    /// phases say it did.
    pub fn verb(&self) -> String {
        if let Some(verb) = self.args.first() {
            return verb.clone();
        }
        let has = |id: &str| self.phases.iter().any(|p| p.id == id);
        if has("land") || has("clearance") || has("closures") {
            "land".into()
        } else if has("push") {
            "dispatch".into()
        } else if has("park") {
            "park".into()
        } else if has("preflight") {
            "preflight".into()
        } else {
            "run".into()
        }
    }

    pub fn command(&self) -> String {
        if self.args.is_empty() {
            format!("ci {} (job-log)", self.verb())
        } else {
            format!("ci {}", self.args.join(" "))
        }
    }

    /// The phase in progress, or the last one reported.
    pub fn current_phase(&self) -> Option<&Phase> {
        self.phases
            .iter()
            .rev()
            .find(|p| {
                matches!(
                    p.state,
                    PhaseState::Working | PhaseState::Blocked | PhaseState::Permission
                )
            })
            .or_else(|| self.phases.last())
    }

    pub fn failed_phase(&self) -> Option<&Phase> {
        self.phases
            .iter()
            .rev()
            .find(|p| p.state == PhaseState::Error)
    }
}

pub fn state_home() -> PathBuf {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .unwrap_or_else(|| home().join(".local").join("state"))
}

pub fn home() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}

pub fn store_dir() -> PathBuf {
    state_home().join("ci-mcp").join("jobs")
}

fn xs_store() -> String {
    std::env::var("XS_ADDR").unwrap_or_else(|_| {
        home()
            .join(".local/share/cross.stream/store")
            .to_string_lossy()
            .into_owned()
    })
}

pub fn alive(pid: i32) -> bool {
    // SAFETY: signal 0 only checks that the process exists.
    pid > 0
        && (unsafe { libc::kill(pid, 0) } == 0
            || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM))
}

/// Folds OSC 7501 records into phases, in the order they first appeared.
pub fn parse_phases(text: &str) -> (Vec<Phase>, Option<(PhaseState, String)>, Option<i64>) {
    let mut phases: Vec<Phase> = Vec::new();
    let mut summary = None;
    let mut last_time = None;
    for line in text.lines() {
        let Ok(record) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let field = |key: &str| record.get(key).and_then(|v| v.as_str()).map(str::to_string);
        let Some(state) = field("state") else {
            continue;
        };
        let at = field("time").and_then(|t| time::parse(&t));
        last_time = at.or(last_time);
        let msg = field("msg").unwrap_or_default();
        let parsed = match state.as_str() {
            "working" => PhaseState::Working,
            "done" => PhaseState::Done,
            "error" => PhaseState::Error,
            "blocked" if field("kind").as_deref() == Some("permission") => PhaseState::Permission,
            "blocked" => PhaseState::Blocked,
            "clear" => {
                // A cleared wait is over; a bare clear only tells terminals
                // to drop their records.
                if let Some(id) = field("id") {
                    if let Some(phase) = phases.iter_mut().find(|p| p.id == id) {
                        if matches!(phase.state, PhaseState::Blocked | PhaseState::Permission) {
                            phase.state = PhaseState::Done;
                            phase.ended_ms = at;
                        }
                    }
                }
                continue;
            }
            _ => continue,
        };
        let Some(id) = field("id") else {
            if !msg.is_empty() {
                summary = Some((parsed, msg));
            }
            continue;
        };
        let index = match phases.iter().position(|p| p.id == id) {
            Some(index) => index,
            None => {
                phases.push(Phase {
                    id,
                    state: parsed,
                    msg: String::new(),
                    started_ms: at,
                    ended_ms: None,
                });
                phases.len() - 1
            }
        };
        let phase = &mut phases[index];
        if !msg.is_empty() {
            phase.msg = msg;
        }
        phase.state = parsed;
        match parsed {
            PhaseState::Done | PhaseState::Error => phase.ended_ms = at,
            _ => phase.ended_ms = None,
        }
    }
    (phases, summary, last_time)
}

fn mtime_ms(path: &Path) -> Option<i64> {
    let modified = fs::metadata(path).ok()?.modified().ok()?;
    Some(
        modified
            .duration_since(std::time::UNIX_EPOCH)
            .ok()?
            .as_millis() as i64,
    )
}

/// A finished run never changes, so the scanner keeps it.
#[derive(Default)]
pub struct Scanner {
    finished: HashMap<String, Run>,
    shell: Vec<(String, PathBuf, PathBuf, Option<i32>)>,
    shell_checked_ms: i64,
}

/// How many of the newest store jobs to read.
const RECENT: usize = 60;

impl Scanner {
    fn store_run(&mut self, dir: &Path) -> Option<Run> {
        let id = dir.file_name()?.to_string_lossy().into_owned();
        if let Some(run) = self.finished.get(&id) {
            return Some(run.clone());
        }
        let meta: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(dir.join("meta.json")).ok()?).ok()?;
        let args: Vec<String> = meta
            .get("args")
            .and_then(|a| a.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default();
        let pid = meta.get("pid").and_then(|p| p.as_i64()).map(|p| p as i32);
        let started_ms = meta
            .get("started")
            .and_then(|s| s.as_str())
            .and_then(time::parse)
            .unwrap_or(0);
        let log = dir.join("log");
        let status_file = dir.join("log.status.jsonl");
        let (phases, summary, last) =
            parse_phases(&fs::read_to_string(&status_file).unwrap_or_default());
        let exit_file = dir.join("exit");
        let exit_code = fs::read_to_string(&exit_file)
            .ok()
            .map(|code| code.trim().parse().unwrap_or(1));
        let state = match exit_code {
            Some(0) => RunState::Succeeded,
            Some(_) => RunState::Failed,
            None if pid.is_some_and(alive) => RunState::Running,
            None => RunState::Lost,
        };
        let ended_ms = match state {
            RunState::Running => None,
            RunState::Lost => last.or_else(|| mtime_ms(&log)),
            _ => mtime_ms(&exit_file).or(last),
        };
        let run = Run {
            id: id.clone(),
            source: Source::Store,
            args,
            workspace: PathBuf::from(meta.get("workspace").and_then(|w| w.as_str()).unwrap_or("")),
            log,
            status_file,
            started_ms,
            ended_ms,
            state,
            exit_code,
            phases,
            summary,
            mutating: meta
                .get("mutating")
                .and_then(|m| m.as_bool())
                .unwrap_or(true),
            pid,
        };
        if matches!(state, RunState::Succeeded | RunState::Failed) {
            self.finished.insert(id, run.clone());
        }
        Some(run)
    }

    /// `job-log` jobs whose status records come from `ci`, found through
    /// their cross.stream announcements every few seconds.
    fn refresh_shell_jobs(&mut self, now: i64) {
        if now - self.shell_checked_ms < 5_000 {
            return;
        }
        self.shell_checked_ms = now;
        let Ok(output) = Command::new("xs")
            .args(["cat", &xs_store(), "--topic", "job.*"])
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        else {
            return;
        };
        let store = store_dir();
        let mut jobs = Vec::new();
        for line in String::from_utf8_lossy(&output.stdout).lines() {
            let Ok(frame) = serde_json::from_str::<serde_json::Value>(line) else {
                continue;
            };
            let topic = frame.get("topic").and_then(|t| t.as_str()).unwrap_or("");
            let Some(id) = topic.strip_suffix(".start") else {
                continue;
            };
            let meta = frame.get("meta");
            let Some(log) = meta.and_then(|m| m.get("log")).and_then(|l| l.as_str()) else {
                continue;
            };
            let log = PathBuf::from(log);
            if log.starts_with(&store) {
                continue;
            }
            let cwd = PathBuf::from(
                meta.and_then(|m| m.get("cwd"))
                    .and_then(|c| c.as_str())
                    .unwrap_or(""),
            );
            let pid = meta
                .and_then(|m| m.get("pid"))
                .and_then(|p| p.as_i64())
                .map(|p| p as i32);
            jobs.push((id.to_string(), log, cwd, pid));
        }
        self.shell = jobs;
    }

    fn shell_run(&mut self, id: &str, log: &Path, cwd: &Path, pid: Option<i32>) -> Option<Run> {
        if let Some(run) = self.finished.get(id) {
            return Some(run.clone());
        }
        let status_file = PathBuf::from(format!("{}.status.jsonl", log.display()));
        let text = fs::read_to_string(&status_file).ok()?;
        if !text.contains(r#""app":"ci""#) {
            return None;
        }
        let (phases, summary, last) = parse_phases(&text);
        let done = PathBuf::from(format!("{}.done.nuon", log.display()));
        // `{exit_code: 0}` or `{exit_code: 1, error: ...}` in NUON.
        let exit_code = fs::read_to_string(&done).ok().map(|nuon| {
            nuon.split("exit_code:")
                .nth(1)
                .and_then(|rest| {
                    rest.trim_start()
                        .split(|c: char| !(c.is_ascii_digit() || c == '-'))
                        .next()?
                        .parse()
                        .ok()
                })
                .unwrap_or(1)
        });
        let state = match exit_code {
            Some(0) => RunState::Succeeded,
            Some(_) => RunState::Failed,
            None if pid.is_some_and(alive) => RunState::Running,
            None => RunState::Lost,
        };
        let started_ms = phases
            .first()
            .and_then(|p| p.started_ms)
            .or_else(|| mtime_ms(log))
            .unwrap_or(0);
        let run = Run {
            id: id.to_string(),
            source: Source::Shell,
            args: vec![],
            workspace: cwd.to_path_buf(),
            log: log.to_path_buf(),
            status_file,
            started_ms,
            ended_ms: if state == RunState::Running {
                None
            } else {
                mtime_ms(&done).or(last)
            },
            state,
            exit_code,
            phases,
            summary,
            mutating: true,
            pid,
        };
        if matches!(state, RunState::Succeeded | RunState::Failed) {
            self.finished.insert(id.to_string(), run.clone());
        }
        Some(run)
    }

    /// Every recent run, newest first.
    pub fn scan(&mut self) -> Vec<Run> {
        let now = time::now_ms();
        let mut dirs: Vec<PathBuf> = fs::read_dir(store_dir())
            .map(|entries| {
                entries
                    .filter_map(|e| e.ok())
                    .map(|e| e.path())
                    .filter(|p| p.is_dir())
                    .collect()
            })
            .unwrap_or_default();
        // Job ids start with their local start time, so names sort by age.
        dirs.sort();
        dirs.reverse();
        let mut runs: Vec<Run> = dirs
            .iter()
            .take(RECENT)
            .filter_map(|dir| self.store_run(dir))
            .collect();
        self.refresh_shell_jobs(now);
        for (id, log, cwd, pid) in self.shell.clone() {
            runs.extend(self.shell_run(&id, &log, &cwd, pid));
        }
        runs.sort_by_key(|run| std::cmp::Reverse(run.started_ms));
        runs
    }
}

fn random_hex(bytes: usize) -> String {
    let mut buffer = vec![0u8; bytes];
    if fs::File::open("/dev/urandom")
        .and_then(|mut f| f.read_exact(&mut buffer))
        .is_err()
    {
        let seed = time::now_ms() as u64 ^ std::process::id() as u64;
        buffer = seed.to_le_bytes()[..bytes].to_vec();
    }
    buffer.iter().map(|b| format!("{b:02x}")).collect()
}

fn local_stamp(format: &str) -> String {
    let now = (time::now_ms() / 1_000) as libc::time_t;
    let format = std::ffi::CString::new(format).unwrap_or_default();
    let mut out = [0u8; 64];
    // SAFETY: localtime_r and strftime write only into the buffers given.
    unsafe {
        let mut tm: libc::tm = std::mem::zeroed();
        libc::localtime_r(&now, &mut tm);
        let len = libc::strftime(out.as_mut_ptr().cast(), out.len(), format.as_ptr(), &tm);
        String::from_utf8_lossy(&out[..len]).into_owned()
    }
}

/// A store job still changing `workspace`, which a new mutating run waits on.
pub fn busy(runs: &[Run], workspace: &Path) -> Option<String> {
    runs.iter()
        .find(|run| run.state == RunState::Running && run.mutating && run.workspace == workspace)
        .map(|run| run.id.clone())
}

/// Starts `ci ARGS` in `workspace` as a detached store job, exactly as the ci
/// MCP server does, and returns its id.
pub fn launch(
    ci: &str,
    args: &[String],
    workspace: &Path,
    mutating: bool,
) -> Result<String, String> {
    let slug: String = args
        .first()
        .map(|a| {
            a.to_lowercase()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect()
        })
        .unwrap_or_else(|| "ci".into());
    let id = format!(
        "{}-{}-{}",
        local_stamp("%Y%m%dT%H%M%S"),
        slug.trim_matches('-'),
        random_hex(3)
    );
    let dir = store_dir().join(&id);
    fs::create_dir_all(&dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    let topic = format!("job.{id}");
    let log = dir.join("log");
    fs::write(&log, "").map_err(|e| e.to_string())?;
    let script = r#""$@" >"$CI_MCP_LOG" 2>&1; code=$?; echo $code >"$CI_MCP_EXIT"; xs append "$CI_MCP_XS" "$CI_MCP_DONE" --meta "{\"outcome\": {\"exit_code\": $code}}" >/dev/null 2>&1"#;
    let mut command = Command::new("sh");
    command
        .args(["-c", script, "ci-mcp-job", ci])
        .args(args)
        .current_dir(workspace)
        .env("NO_COLOR", "1")
        .env("TERM", "dumb")
        .env("COLUMNS", "100")
        .env("CI_MCP_XS", xs_store())
        .env("CI_MCP_DONE", format!("{topic}.done"))
        .env("CI_MCP_LOG", &log)
        .env("CI_MCP_EXIT", dir.join("exit"))
        .env("PST_FILE", dir.join("log.status.jsonl"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: setsid is async-signal-safe; the job outlives the tower and
    // its terminal, as an MCP job outlives its client.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = command
        .spawn()
        .map_err(|e| format!("could not start ci: {e}"))?;
    let pid = child.id();
    std::thread::spawn(move || child.wait());
    let meta = serde_json::json!({
        "args": args,
        "workspace": workspace,
        "mutating": mutating,
        "pid": pid,
        "started": local_stamp("%Y-%m-%dT%H:%M:%S%z"),
        "topic": topic,
    });
    fs::write(dir.join("meta.json"), meta.to_string()).map_err(|e| e.to_string())?;
    let announce = serde_json::json!({ "log": log, "cwd": workspace, "pid": pid }).to_string();
    detach(Command::new("xs").args([
        "append",
        &xs_store(),
        &format!("{topic}.start"),
        "--meta",
        &announce,
    ]));
    Ok(id)
}

/// Stops a running store job's process group, as the MCP `cancel` tool does.
pub fn stop(run: &Run) -> Result<(), String> {
    let pid = run
        .pid
        .filter(|_| run.state == RunState::Running)
        .ok_or("the run is not running")?;
    // SAFETY: signals the job's own process group, which setsid created.
    if unsafe { libc::killpg(pid, libc::SIGTERM) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().to_string())
    }
}

/// Runs a helper in its own session without waiting for it.
pub fn detach(command: &mut Command) -> bool {
    command
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    // SAFETY: as in `launch`.
    unsafe {
        command.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    match command.spawn() {
        Ok(mut child) => {
            std::thread::spawn(move || child.wait());
            true
        }
        Err(_) => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const LANDING: &str = r#"{"time":"2026-10-12T19:31:01.249-05:00","state":"working","id":"rebase","app":"ci","msg":"Rebasing onto main@tangled"}
{"time":"2026-10-12T19:31:03.656-05:00","state":"done","id":"rebase","app":"ci","msg":"Rebasing onto main@tangled"}
{"time":"2026-10-12T19:35:43.800-05:00","state":"blocked","id":"local-checks","app":"ci","msg":"Waiting for local checks of x"}
{"time":"2026-10-12T19:35:50.000-05:00","state":"clear","id":"local-checks","app":"ci"}
{"time":"2026-10-12T19:35:51.000-05:00","state":"working","id":"clearance","app":"ci","msg":"Waiting for local flake checks on asus"}
{"time":"2026-10-12T19:38:49.546-05:00","state":"done","id":"clearance","app":"ci","msg":"local flake checks on asus passed"}
{"time":"2026-10-12T19:38:57.477-05:00","state":"done","app":"ci","msg":"Landed the topic"}
{"time":"2026-10-12T19:38:57.478-05:00","state":"clear","app":"ci"}"#;

    #[test]
    fn folds_records_into_phases() {
        let (phases, summary, last) = parse_phases(LANDING);
        let ids: Vec<_> = phases.iter().map(|p| (p.id.as_str(), p.state)).collect();
        assert_eq!(
            ids,
            [
                ("rebase", PhaseState::Done),
                ("local-checks", PhaseState::Done),
                ("clearance", PhaseState::Done)
            ]
        );
        assert_eq!(
            phases[0].ended_ms.unwrap() - phases[0].started_ms.unwrap(),
            2_407
        );
        assert_eq!(phases[2].msg, "local flake checks on asus passed");
        assert_eq!(summary, Some((PhaseState::Done, "Landed the topic".into())));
        assert!(last.is_some());
    }

    #[test]
    fn a_phase_waiting_on_a_person_is_permission() {
        let (phases, _, _) = parse_phases(
            r#"{"state":"blocked","id":"approval","kind":"permission","msg":"Approve the step"}"#,
        );
        assert_eq!(phases[0].state, PhaseState::Permission);
    }
}
