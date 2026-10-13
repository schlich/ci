//! Background threads that keep the tower current without ever blocking a
//! frame. JJ is read again only when an operation lands in the shared op
//! heads or a workspace record changes, so an idle repository costs a few
//! `stat` calls per tick; runs, locks, and the followed log are polled.

use std::collections::hash_map::DefaultHasher;
use std::fs;
use std::hash::{Hash, Hasher};
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use ratatui::crossterm::event::{self, Event};

use crate::host::{self, HostInfo, LockReader, Locks};
use crate::jobs::{Run, Scanner};
use crate::repo::{self, Snapshot};

pub enum Msg {
    Input(Event),
    Snapshot(Result<Box<Snapshot>, String>),
    Runs(Vec<Run>),
    Locks(Locks),
    Host(HostInfo),
    /// Lines appended to the followed log; `reset` replaces what was shown.
    Log {
        run: String,
        lines: Vec<String>,
        reset: bool,
    },
}

#[derive(Default)]
struct Watched {
    op_heads: Option<PathBuf>,
    records: Vec<PathBuf>,
}

#[derive(Clone)]
pub struct Feed {
    refresh: Sender<()>,
    follow: Arc<Mutex<Option<(String, PathBuf)>>>,
}

impl Feed {
    pub fn refresh(&self) {
        let _ = self.refresh.send(());
    }

    /// Follows `log` for run `id`, or nothing.
    pub fn follow(&self, target: Option<(String, PathBuf)>) {
        if let Ok(mut follow) = self.follow.lock() {
            if *follow != target {
                *follow = target;
            }
        }
    }
}

const TICK: Duration = Duration::from_millis(150);
/// The most of a log read when it is first followed.
const LOG_WINDOW: u64 = 512 * 1024;

fn fingerprint(watched: &Watched) -> u64 {
    let mut hasher = DefaultHasher::new();
    if let Some(dir) = &watched.op_heads {
        if let Ok(entries) = fs::read_dir(dir) {
            let mut names: Vec<_> = entries
                .filter_map(|e| e.ok())
                .map(|e| e.file_name())
                .collect();
            names.sort();
            names.hash(&mut hasher);
        }
    }
    for path in &watched.records {
        fs::metadata(path)
            .and_then(|m| m.modified())
            .ok()
            .hash(&mut hasher);
    }
    hasher.finish()
}

fn runs_fingerprint(runs: &[Run]) -> u64 {
    let mut hasher = DefaultHasher::new();
    for run in runs {
        run.id.hash(&mut hasher);
        (run.state as u8).hash(&mut hasher);
        run.summary.as_ref().map(|s| &s.1).hash(&mut hasher);
        for phase in &run.phases {
            (&phase.id, phase.state as u8, &phase.msg, phase.ended_ms).hash(&mut hasher);
        }
    }
    hasher.finish()
}

struct Tail {
    run: String,
    path: PathBuf,
    offset: u64,
    partial: String,
}

impl Tail {
    /// New complete lines since the last read, or the file's recent end when
    /// it is new or was truncated.
    fn read(&mut self) -> Option<(Vec<String>, bool)> {
        let mut file = fs::File::open(&self.path).ok()?;
        let len = file.metadata().ok()?.len();
        let mut reset = false;
        if len < self.offset || self.offset == u64::MAX {
            reset = true;
            self.offset = len.saturating_sub(LOG_WINDOW);
            self.partial.clear();
        }
        if len == self.offset {
            return reset.then(|| (vec![], true));
        }
        file.seek(SeekFrom::Start(self.offset)).ok()?;
        let mut bytes = Vec::new();
        file.take(len - self.offset).read_to_end(&mut bytes).ok()?;
        self.offset = len;
        let mut text = std::mem::take(&mut self.partial);
        text.push_str(&String::from_utf8_lossy(&bytes));
        if reset && self.offset > LOG_WINDOW {
            // The window starts mid-line; drop the fragment.
            if let Some(at) = text.find('\n') {
                text.drain(..=at);
            }
        }
        let mut lines: Vec<String> = text.split('\n').map(str::to_string).collect();
        self.partial = lines.pop().unwrap_or_default();
        Some((lines, reset))
    }
}

pub fn start(dir: PathBuf, tx: Sender<Msg>) -> Feed {
    let (refresh_tx, refresh_rx) = mpsc::channel::<()>();
    let follow: Arc<Mutex<Option<(String, PathBuf)>>> = Arc::default();
    let watched: Arc<Mutex<Watched>> = Arc::default();

    // Input: forwarded as it arrives, so a key never waits on a tick.
    let input = tx.clone();
    std::thread::spawn(move || {
        while let Ok(event) = event::read() {
            if input.send(Msg::Input(event)).is_err() {
                break;
            }
        }
    });

    // JJ: read on demand, at most once per burst of operations.
    let snapshots = tx.clone();
    let shared = watched.clone();
    std::thread::spawn(move || loop {
        let result = repo::snapshot(&dir);
        if let (Ok(snapshot), Ok(mut watched)) = (&result, shared.lock()) {
            watched.op_heads = snapshot.op_heads.clone();
            watched.records = snapshot
                .workspace_roots
                .iter()
                .flat_map(|root| repo::record_files(root))
                .collect();
        }
        if snapshots.send(Msg::Snapshot(result.map(Box::new))).is_err() {
            break;
        }
        match refresh_rx.recv_timeout(Duration::from_secs(60)) {
            Ok(()) | Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        // Coalesce the burst a dispatch or landing makes.
        std::thread::sleep(Duration::from_millis(120));
        while refresh_rx.try_recv().is_ok() {}
    });

    let poller_follow = follow.clone();
    let poller_refresh = refresh_tx.clone();
    std::thread::spawn(move || {
        let mut scanner = Scanner::default();
        let mut locks = LockReader::default();
        let mut last_print = None;
        let mut last_runs = None;
        let mut last_locks = None;
        let mut last_host = None;
        let mut tail: Option<Tail> = None;
        let started = Instant::now();
        let mut tick: u64 = 0;
        loop {
            let at = started + TICK * tick as u32;
            if let Some(wait) = at.checked_duration_since(Instant::now()) {
                std::thread::sleep(wait);
            }
            tick += 1;

            let print = watched.lock().map(|w| fingerprint(&w)).ok();
            if last_print.is_some() && print != last_print {
                let _ = poller_refresh.send(());
            }
            last_print = print;

            if tick % 3 == 1 {
                let runs = scanner.scan();
                let print = runs_fingerprint(&runs);
                if last_runs != Some(print) {
                    last_runs = Some(print);
                    if tx.send(Msg::Runs(runs)).is_err() {
                        break;
                    }
                }
            }
            if tick % 6 == 1 {
                let now = locks.read();
                if last_locks.as_ref() != Some(&now) {
                    last_locks = Some(now.clone());
                    let _ = tx.send(Msg::Locks(now));
                }
            }
            if tick % 33 == 1 {
                let now = host::host_info();
                if last_host.as_ref() != Some(&now) {
                    last_host = Some(now.clone());
                    let _ = tx.send(Msg::Host(now));
                }
            }

            let target = poller_follow.lock().ok().and_then(|f| f.clone());
            match (&target, &mut tail) {
                (None, _) => tail = None,
                (Some((run, path)), Some(current))
                    if current.run == *run && current.path == *path => {}
                (Some((run, path)), _) => {
                    tail = Some(Tail {
                        run: run.clone(),
                        path: path.clone(),
                        offset: u64::MAX,
                        partial: String::new(),
                    });
                }
            }
            if let Some(current) = &mut tail {
                if let Some((lines, reset)) = current.read() {
                    if (reset || !lines.is_empty())
                        && tx
                            .send(Msg::Log {
                                run: current.run.clone(),
                                lines,
                                reset,
                            })
                            .is_err()
                    {
                        break;
                    }
                }
            }
        }
    });

    Feed {
        refresh: refresh_tx,
        follow,
    }
}
